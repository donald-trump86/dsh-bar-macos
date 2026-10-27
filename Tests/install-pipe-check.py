#!/usr/bin/env python3
"""Compile the complete installer backend; use only loopback HTTP and a dummy npm."""
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = bytes(range(256)) * 2048

STUBS = r'''
import Foundation
import Darwin

enum LocalizationKey: String {
    case installTagInvalid, installAlreadyRunning, installNoOutput, installFailedBody
    case installNpmNotFound, installCouldNotStart, installCancelled
    case tagProbeOffline, tagProbeTimedOut, tagProbeNotFound, tagProbeBadResponse
}
func L(_ key: LocalizationKey, _ values: [String: String] = [:]) -> String {
    key.rawValue + (values["reason"].map { ": " + $0 } ?? "")
}
final class ServiceManager {
    static let shared = ServiceManager()
    static let installCommand = "npm install -g @deepseek-ai/dsh"
    var executable: String? = CommandLine.arguments[1]
    static var mode = "success"
    func findNpmBinary() -> String? { executable }
    static func commandEnvironment() -> [String: String] {
        ["PATH": "/usr/bin:/bin", "INSTALL_PIPE_SENTINEL": "preserved", "MODE": mode,
         "FIXTURE_ROOT": CommandLine.arguments[3]]
    }
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: " + message + "\n", stderr); exit(1) }
}
func spin(_ duration: TimeInterval) {
    let until = Date().addingTimeInterval(duration)
    while Date() < until { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
}
func pump(_ condition: () -> Bool) {
    let until = Date().addingTimeInterval(15)
    while !condition() && Date() < until { spin(0.005) }
    expect(condition(), "fixture deadline expired")
}
let root = URL(fileURLWithPath: CommandLine.arguments[3])
let archives = root.appendingPathComponent("archives")
try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
var cancelStage: InstallActivity.Phase?
var controller: DshVersionController!
controller = DshVersionController(fixtureOrigin: URL(string: CommandLine.arguments[2])!, temporaryRoot: archives,
    stageObserver: { phase in
        if phase == cancelStage { DispatchQueue.main.sync { controller.cancelInstall() } }
    })
let executable = CommandLine.arguments[1]
let started = root.appendingPathComponent("started")
let childPID = root.appendingPathComponent("child-pid")
var completions = 0
func invoke(_ tag: String = "latest", mode: String = "success",
            cancel: ((InstallActivity) -> Bool)? = nil, immediate: Bool = false,
            failureToSpawn: Bool = false, observe: ((InstallActivity) -> Void)? = nil) -> Result<String, Error> {
    try? FileManager.default.removeItem(at: started)
    try? FileManager.default.removeItem(at: childPID)
    ServiceManager.mode = mode
    ServiceManager.shared.executable = failureToSpawn ? executable + ".missing" : executable
    var result: Result<String, Error>?
    var calls = 0
    var rejected = false
    controller.install(tag: tag) {
        expect(Thread.isMainThread, "completion left main thread")
        expect(!controller.isInstalling && controller.installActivity == nil, "completed before clearing busy")
        result = $0; calls += 1; completions += 1
    }
    expect(controller.isInstalling, "no initial busy state")
    expect(controller.installActivity?.tag == tag, "lost tag")
    let start = controller.installActivity!.startedAt
    controller.install(tag: "next") {
        guard case .failure(let error) = $0,
              case .alreadyInstalling = error as? DshVersionControllerError else {
            expect(false, "concurrent run was not excluded"); return
        }
        rejected = true
    }
    if immediate { controller.cancelInstall(); controller.cancelInstall() }
    var didCancel = immediate
    pump {
        if let activity = controller.installActivity {
            expect(activity.startedAt == start, "start time reset")
            expect(activity.outputTail.utf8.count <= 65536, "snapshot exceeded log bound")
            observe?(activity)
            if !didCancel && (cancel?(activity) ?? false) {
                controller.cancelInstall(); controller.cancelInstall(); didCancel = true
                expect(controller.installActivity?.phase == .cancelling, "cancel phase missing")
                expect(controller.isInstalling, "cancel cleared busy before cleanup")
            }
        }
        return result != nil && rejected
    }
    spin(0.05)
    expect(calls == 1, "completion repeated")
    expect(controller.lastInstallLog.utf8.count <= 65536, "final log exceeded bound")
    expect(try! FileManager.default.contentsOfDirectory(atPath: archives.path).isEmpty, "archive leaked")
    return result!
}
func success(_ result: Result<String, Error>) {
    guard case .success(let output) = result else { expect(false, "expected success: \(result)"); return }
    expect(output.isEmpty, "success payload changed")
}
func cancelled(_ result: Result<String, Error>) {
    guard case .failure(let error) = result,
          case .cancelled = error as? DshVersionControllerError else {
        expect(false, "expected cancellation: \(result)"); return
    }
}
func backendFailure(_ result: Result<String, Error>, contains text: String) {
    guard case .failure(let error) = result,
          case .installCouldNotStart(let detail) = error as? DshVersionControllerError else {
        expect(false, "expected wrapped backend failure: \(result)"); return
    }
    expect(detail.contains(text), "missing failure detail: \(detail)")
    expect(!FileManager.default.fileExists(atPath: started.path), "npm ran before validation")
}
func checkTermination(_ tag: String?, mode: String = "success") {
    let quitting = DshVersionController(fixtureOrigin: URL(string: CommandLine.arguments[2])!, temporaryRoot: archives)
    try? FileManager.default.removeItem(at: childPID)
    ServiceManager.mode = mode
    ServiceManager.shared.executable = executable
    var originalCalls = 0
    if let tag {
        quitting.install(tag: tag) { result in
            expect(Thread.isMainThread && !quitting.isInstalling && quitting.isTerminating,
                   "termination result arrived before cleanup")
            cancelled(result)
            originalCalls += 1
        }
        pump {
            if mode == "cancel" { return FileManager.default.fileExists(atPath: childPID.path) }
            return quitting.installActivity?.phase == .downloading && (quitting.installActivity?.bytesReceived ?? 0) > 0
        }
    }
    var waiters = 0
    for _ in 0..<2 {
        quitting.cancelInstallForTermination {
            expect(Thread.isMainThread && !quitting.isInstalling && quitting.isTerminating,
                   "quit waiter arrived before cleanup")
            expect(originalCalls == (tag == nil ? 0 : 1), "quit waiter preceded result")
            expect(try! FileManager.default.contentsOfDirectory(atPath: archives.path).isEmpty, "quit leaked archive")
            waiters += 1
        }
    }
    expect(waiters == 0, "quit callback was synchronous")
    pump { waiters == 2 }
    var rejected = false
    quitting.install(tag: "latest") { result in cancelled(result); rejected = true }
    expect(!quitting.isInstalling, "new install started during termination")
    pump { rejected }
    if mode == "cancel" {
        let pid = Int32(try! String(contentsOf: childPID, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        expect(kill(pid, 0) != 0 && errno == ESRCH, "quit left owned child alive")
    }
}
'''

PIPE_CHECKS = r'''
success(invoke())
expect(controller.lastInstallLog.contains("Installation completed"), "success log not retained")
let noisy = invoke(mode: "failure")
if case .failure(let error) = noisy,
   case .installFailed(let code, let output) = error as? DshVersionControllerError {
    expect(code == 23, "exit status changed")
    expect(output.utf8.count <= 65536, "error log exceeded bound")
    expect(!output.contains("BEGIN-OUTPUT"), "unbounded output prefix retained")
    expect(output.hasSuffix("STDOUT-END\nSTDERR-END"), "merged diagnostic tail lost")
    expect(output.contains("\u{fffd}"), "invalid UTF8 dropped diagnostics")
} else { expect(false, "noisy failure lost") }
let empty = invoke(mode: "empty")
if case .failure(let error) = empty,
   case .installFailed(let code, _) = error as? DshVersionControllerError {
    expect(code == 24, "empty error exit lost")
} else { expect(false, "empty failure lost") }
backendFailure(invoke(failureToSpawn: true), contains: "file")
var silentSeen = false
success(invoke(mode: "silent", observe: { a in
    if a.phase == .installing && a.elapsed(at: ProcessInfo.processInfo.systemUptime) >= "0:01" { silentSeen = true }
}))
expect(silentSeen, "elapsed time did not advance without output")
success(invoke(mode: "redact"))
expect(!controller.lastInstallLog.contains("fixture-secret"), "credential-shaped logs were exposed")
let began = ProcessInfo.processInfo.systemUptime
success(invoke(mode: "held"))
expect(ProcessInfo.processInfo.systemUptime - began < 4, "held pipe stalled exit observation")
let heldPID = Int32(try String(contentsOf: childPID, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
expect(kill(heldPID, 0) != 0 && errno == ESRCH, "ordinary-exit child survived cleanup")
cancelled(invoke(mode: "cancel", cancel: { _ in FileManager.default.fileExists(atPath: childPID.path) }))
let cancelPID = Int32(try String(contentsOf: childPID, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
expect(kill(cancelPID, 0) != 0 && errno == ESRCH, "cancelled group child survived")
cancelled(invoke(immediate: true))
expect(!FileManager.default.fileExists(atPath: started.path), "immediate cancellation spawned npm")
success(invoke())
for tag in ["bad;tag", "latest"] {
    if tag == "latest" { ServiceManager.shared.executable = nil }
    var done = false
    controller.install(tag: tag) { result in
        expect(Thread.isMainThread, "preflight callback left main thread")
        guard case .failure = result else { expect(false, "preflight accepted invalid input"); return }
        done = true
    }
    expect(!controller.isInstalling, "preflight failure became busy")
    pump { done }
}
expect(completions == 10, "unexpected completion count")
checkTermination(nil)
checkTermination("latest", mode: "cancel")
print("PASS install pipe: 10 runs + idle/npm termination; noisy/silent/malformed logs, 64KiB bound, exclusion, spawn failure, owned group cancellation, held pipe cleanup, reuse, redaction")
'''

DOWNLOAD_CHECKS = r'''
var sawRate = false, sawStall = false, sawKnown = false, sawPinned = false
success(invoke("slow", observe: { a in
    if a.phase == .downloading {
        if a.bytesPerSecond > 0 { sawRate = true }
        if a.bytesReceived > 0 && a.bytesPerSecond == 0 { sawStall = true }
        if a.totalBytes == 524288 { sawKnown = true }
    }
    if a.version == "1.0.1" { sawPinned = true }
}))
expect(sawRate && sawStall && sawKnown && sawPinned, "truthful known-length telemetry missing")
var sawUnknown = false
success(invoke("unknown", observe: { a in
    if a.phase == .downloading && a.bytesReceived > 0 {
        expect(a.totalBytes == nil, "invented unknown length")
        sawUnknown = true
    }
}))
expect(sawUnknown, "unknown-length transfer not sampled")
backendFailure(invoke("mismatch"), contains: "integrity mismatch")
backendFailure(invoke("http-error"), contains: "HTTP 503")
backendFailure(invoke("archive-error"), contains: "HTTP 502")
for tag in ["untrusted", "credentials", "wrong-name", "wrong-version", "missing-integrity", "wrong-path"] {
    backendFailure(invoke(tag), contains: "Invalid official")
}
backendFailure(invoke("redirect"), contains: "redirect")
backendFailure(invoke("metadata-big"), contains: "1 MiB")
cancelled(invoke("resolve-wait", cancel: { $0.phase == .resolving }))
expect(!FileManager.default.fileExists(atPath: started.path), "resolving cancel spawned npm")
cancelled(invoke("slow", cancel: { $0.phase == .downloading && $0.bytesReceived > 0 }))
expect(!FileManager.default.fileExists(atPath: started.path), "download cancel spawned npm")
for phase in [InstallActivity.Phase.downloading, .verifying, .installing] {
    cancelStage = phase
    cancelled(invoke())
    expect(!FileManager.default.fileExists(atPath: started.path), "stage cancellation spawned npm")
    cancelStage = nil
}
checkTermination("slow")
success(invoke())
print("PASS install download: 19 runs + download termination; real bytes/rate/stall, known/unknown length, pinned metadata, SHA512 mismatch, HTTP failures, URL/credential/redirect/name/version/integrity rejection, all stage cancellations, cleanup/reuse")
'''


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *_):
        pass

    def do_GET(self):
        try:
            self.respond()
        except (BrokenPipeError, ConnectionResetError):
            pass  # Cancellation intentionally closes a live transfer.

    def send(self, status, body, *, length=True, delay=0, stall=False):
        self.send_response(status)
        if length:
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        for offset in range(0, len(body), 16384):
            self.wfile.write(body[offset:offset + 16384])
            self.wfile.flush()
            if stall and offset == 32768:
                time.sleep(0.7)
            if delay:
                time.sleep(delay)

    def respond(self):
        if "/-/dsh-" in self.path:
            version = self.path.rsplit("dsh-", 1)[1].removesuffix(".tgz")
            mode = self.server.versions[version]
            if mode == "archive-error":
                return self.send(502, b"archive unavailable")
            if mode == "redirect":
                self.send_response(302)
                self.send_header("Location", "http://127.0.0.1:1/never-contact")
                self.end_headers()
                return
            return self.send(200, PAYLOAD, length=mode != "unknown",
                             delay=0.02 if mode in ("slow", "unknown") else 0,
                             stall=mode == "slow")
        tag = self.path.rsplit("/", 1)[1]
        if tag == "http-error":
            return self.send(503, b"unavailable")
        if tag == "resolve-wait":
            time.sleep(0.5)
        if tag == "metadata-big":
            return self.send(200, b" " * (1024 * 1024 + 1))
        version = self.server.tags[tag]
        url = f"http://127.0.0.1:{self.server.server_port}/@deepseek-ai/dsh/-/dsh-{version}.tgz"
        if tag == "untrusted":
            url = url.replace("127.0.0.1", "example.invalid")
        elif tag == "credentials":
            url = url.replace("127.0.0.1", "user:fixture-secret@127.0.0.1")
        elif tag == "wrong-path":
            url = url.replace("/dsh/-/", "/other/-/")
        digest = hashlib.sha512(PAYLOAD if tag != "mismatch" else b"mismatch").digest()
        document = {
            "name": "other" if tag == "wrong-name" else "@deepseek-ai/dsh",
            "version": "../escape" if tag == "wrong-version" else version,
            "dist": {"tarball": url, "integrity": "sha512-" + base64.b64encode(digest).decode()},
        }
        if tag == "missing-integrity":
            del document["dist"]["integrity"]
        self.send(200, json.dumps(document).encode())


def run_fixture(command, env):
    process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=45)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise AssertionError("full installer fixture exceeded watchdog")
    if process.returncode:
        raise AssertionError(f"fixture exited {process.returncode}:\n"
                             + stderr.decode(errors="replace") + stdout.decode(errors="replace"))
    print(stdout.decode(), end="")


def main(suite="pipe"):
    temp_root = Path(tempfile.gettempdir()).resolve()
    work = Path(tempfile.mkdtemp(prefix="dsh-install-fixture-", dir=temp_root)).resolve()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    tags = ["latest", "slow", "unknown", "mismatch", "http-error", "archive-error", "untrusted",
            "credentials", "wrong-name", "wrong-version", "missing-integrity", "wrong-path",
            "redirect", "metadata-big", "resolve-wait"]
    server.tags = {tag: f"1.0.{index}" for index, tag in enumerate(tags)}
    server.versions = {version: tag for tag, version in server.tags.items()}
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        swift = work / "main.swift"
        swift.write_text(STUBS + (PIPE_CHECKS if suite == "pipe" else DOWNLOAD_CHECKS))
        dummy = work / "dummy-npm"
        dummy.write_text(f"#!{sys.executable}\n" + '''import hashlib
import os
from pathlib import Path
import signal
import sys
import time
assert sys.argv[1:3] == ["install", "-g"]
assert sys.argv[4:] == ["--loglevel", "http"]
archive = Path(sys.argv[3])
assert archive.is_absolute() and archive.name == "package.tgz"
assert archive.stat().st_mode & 0o777 == 0o600
assert archive.parent.stat().st_mode & 0o777 == 0o700
assert hashlib.sha512(archive.read_bytes()).digest() == hashlib.sha512(bytes(range(256)) * 2048).digest()
assert os.environ["INSTALL_PIPE_SENTINEL"] == "preserved"
root = Path(os.environ["FIXTURE_ROOT"])
(root / "started").write_text(str(os.getpid()))
mode = os.environ["MODE"]
signal.alarm(12)
if mode in ("held", "cancel"):
    child = os.fork()
    if child == 0:
        signal.alarm(12)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True:
            time.sleep(1)
    (root / "child-pid").write_text(str(child))
    if mode == "held":
        sys.exit(0)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        time.sleep(1)
if mode == "silent":
    time.sleep(1.3)
    sys.exit(0)
if mode == "empty":
    sys.exit(24)
if mode == "redact":
    print("https://user:fixture-secret@example.invalid/file")
    print("Authorization: Bearer fixture-secret")
    print("_authToken=fixture-secret")
    sys.exit(0)
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
        binary = work / "installer-fixture"
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cache), SWIFT_MODULECACHE_PATH=str(cache))
        compiled = subprocess.run(["swiftc", "-Onone", "-module-cache-path", str(cache),
                                   str(ROOT / "Sources/DshVersionController.swift"),
                                   str(ROOT / "Sources/InstallProcess.swift"), str(swift), "-o", str(binary)],
                                  env=env, capture_output=True, text=True)
        if compiled.returncode:
            raise AssertionError("could not compile complete installer backend:\n" + compiled.stderr)
        if compiled.stderr:
            print(compiled.stderr, file=sys.stderr, end="")
        run_fixture([str(binary), str(dummy), f"http://127.0.0.1:{server.server_port}", str(work)], env)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
        # Verify exactly the directory created above before removing fixture artifacts.
        assert work.is_absolute() and work.resolve() == work and work.parent == temp_root
        assert work.name.startswith("dsh-install-fixture-") and work != ROOT and ROOT / "build" not in work.parents
        shutil.rmtree(work)


if __name__ == "__main__":
    main()
