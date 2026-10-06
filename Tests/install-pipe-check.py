#!/usr/bin/env python3
"""Exercise the real install worker with a noisy local executable, never npm.

Only ServiceManager/localization and unrelated probe code are stubbed. Compiler
artifacts and module cache live in a unique temporary directory, not build/.
The test-only watchdog kills its own fixture process group on a regression.
"""
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sources/DshVersionController.swift"


def extract(source, pattern):
    match = re.search(pattern, source, re.MULTILINE | re.DOTALL)
    if match is None:
        raise AssertionError(f"production source not found: {pattern}")
    return match.group(0)


def run_fixture(command, env):
    process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        # Only the session created above (harness + dummy child), never services.
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise AssertionError("install fixture hung while draining output")
    if process.returncode:
        # A failing harness may exit before its blocked dummy child does.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        raise AssertionError(f"fixture exited {process.returncode}:\n"
                             + stderr.decode(errors="replace")
                             + stdout.decode(errors="replace"))
    print(stdout.decode(), end="")


def main():
    source = SOURCE.read_text()
    methods = "\n".join(extract(source, rf"^    {signature}.*?^    }}$")
                        for signature in [r"static func validTag\(",
                                          r"static func installCommand\(",
                                          r"func install\("])
    fields = "\n".join(extract(source, pattern) for pattern in [
        r"^    private var installInFlight = false$",
        r"^    private\(set\) var isInstalling = false$",
    ])
    errors = extract(source, r"^enum DshVersionControllerError: LocalizedError \{.*?^}$")
    environment = r'''
enum LocalizationKey: String {
    case installTagInvalid, installAlreadyRunning, installNoOutput
    case installFailedBody, installNpmNotFound, installCouldNotStart
}
func L(_ key: LocalizationKey, _ values: [String: String] = [:]) -> String {
    key.rawValue
}
final class ServiceManager {
    static let shared = ServiceManager()
    static let installCommand = "npm install -g @deepseek-ai/dsh"
    var executable: String? = CommandLine.arguments[1]
    static var mode = "success"
    func findNpmBinary() -> String? { executable }
    static func commandEnvironment() -> [String: String] {
        ["PATH": "/usr/bin:/bin", "INSTALL_PIPE_SENTINEL": "preserved", "MODE": mode]
    }
}
'''
    checks = r'''
func expect(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}
func pump(until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(10)
    while !condition() && Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    expect(condition(), "completion did not arrive")
}
let controller = DshVersionController()
let executable = CommandLine.arguments[1]
var totalCompletions = 0
func install(_ mode: String, runFailure: Bool = false) -> Result<String, Error> {
    ServiceManager.mode = mode
    ServiceManager.shared.executable = runFailure ? executable + ".missing" : executable
    var result: Result<String, Error>?
    var rejected = false
    var calls = 0
    controller.install(tag: "latest") {
        expect(Thread.isMainThread, "callback left the main thread")
        expect(!controller.isInstalling, "busy state was not reset before completion")
        result = $0
        calls += 1
        totalCompletions += 1
    }
    expect(controller.isInstalling, "install never set busy state")
    controller.install(tag: "next") {
        expect(Thread.isMainThread, "exclusion callback left main thread")
        guard case .failure(let error) = $0,
              case .alreadyInstalling = error as? DshVersionControllerError else {
            expect(false, "second install was not excluded")
            return
        }
        rejected = true
    }
    pump { result != nil && rejected }
    let settle = Date().addingTimeInterval(0.05)
    while Date() < settle {
        _ = RunLoop.main.run(mode: .default, before: settle)
    }
    expect(calls == 1, "install completed more than once")
    expect(!controller.isInstalling, "busy state remained set")
    return result!
}
func expectSuccess(_ result: Result<String, Error>) {
    guard case .success(let output) = result else {
        expect(false, "expected success, got \(result)")
        return
    }
    expect(output.isEmpty, "success callback changed its empty payload")
}
expectSuccess(install("success"))
if case .failure(let error) = install("failure"),
   case .installFailed(let code, let output) = error as? DshVersionControllerError {
    expect(code == 23, "wrong failure exit code")
    // Lossy UTF-8 decoding may expand a split scalar by up to two bytes.
    expect(output.utf8.count <= 64 * 1024 + 2, "retained error exceeded 64 KiB")
    expect(!output.contains("BEGIN-OUTPUT"), "capture retained the unbounded prefix")
    expect(output.hasSuffix("STDOUT-END\nSTDERR-END"), "merged error tail was lost")
    expect(output.contains("\u{FFFD}"), "malformed UTF-8 discarded all diagnostics")
} else {
    expect(false, "noisy failure was not reported")
}
if case .failure(let error) = install("empty"),
   case .installFailed(let code, let output) = error as? DshVersionControllerError {
    expect(code == 24 && output.isEmpty, "empty failure changed its output/status")
} else {
    expect(false, "empty failure was not reported")
}
if case .failure(let error) = install("success", runFailure: true),
   case .installCouldNotStart(let message) = error as? DshVersionControllerError {
    expect(!message.isEmpty, "run failure lost its reason")
} else {
    expect(false, "run failure was not reported")
}
// Reuse after every outcome also verifies the private exclusion flag reset.
expectSuccess(install("success"))
expect(totalCompletions == 5, "wrong completion count")
print("PASS install pipe: noisy success/failure, bounded tail, exclusion, reset, run failure")
'''
    # Capture the absolute temp root before creating anything; cleanup verifies it.
    temp_root = Path(tempfile.gettempdir()).resolve()
    work = Path(tempfile.mkdtemp(prefix="dsh-install-pipe-", dir=temp_root)).resolve()
    try:
        assert work.parent == temp_root and work.name.startswith("dsh-install-pipe-")
        swift = work / "main.swift"
        swift.write_text("import Foundation\n" + environment + errors
                         + "\nfinal class DshVersionController {\n"
                         + fields + "\n" + methods + "\n}\n" + checks)
        dummy = work / "dummy-npm"
        dummy.write_text(f"#!{sys.executable}\n" + '''import os
import sys
assert sys.argv[1:] == ["install", "-g", "@deepseek-ai/dsh@latest"]
assert os.environ["INSTALL_PIPE_SENTINEL"] == "preserved"
mode = os.environ["MODE"]
if mode == "empty":
    sys.exit(24)
os.write(1, b"BEGIN-OUTPUT\\n")
for _ in range(128):
    os.write(1, b"x" * 8192)
    os.write(2, b"y" * 8192)
os.write(2, b"\\xff\\n")
os.write(1, b"STDOUT-END\\n")
os.write(2, b"STDERR-END\\n")
sys.exit(23 if mode == "failure" else 0)
''')
        dummy.chmod(0o700)
        cache = work / "module-cache"
        cache.mkdir()
        binary = work / "install-pipe"
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cache),
                   SWIFT_MODULECACHE_PATH=str(cache))
        compiled = subprocess.run(["swiftc", "-Onone", "-module-cache-path", str(cache),
                                   str(swift), "-o", str(binary)], env=env,
                                  capture_output=True, text=True)
        if compiled.returncode:
            raise AssertionError("could not compile install worker:\n" + compiled.stderr)
        run_fixture([str(binary), str(dummy)], env)
    finally:
        # Refuse a changed/symlinked or unexpected target before recursive removal.
        assert work.is_absolute() and work.resolve() == work
        assert work.parent == temp_root and work.name.startswith("dsh-install-pipe-")
        # Honor an isolated caller TMPDIR inside the checkout, but never build/.
        assert work != ROOT and work != ROOT / "build" and ROOT / "build" not in work.parents
        shutil.rmtree(work)


if __name__ == "__main__":
    main()
