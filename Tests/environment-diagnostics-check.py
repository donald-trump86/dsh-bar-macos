#!/usr/bin/env python3
"""Exercise production command inspection and rechecks with isolated executables."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Sources/ServiceManager.swift").read_text()


def member(marker):
    start = SOURCE.index(marker)
    opening = SOURCE.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        depth += (SOURCE[cursor] == "{") - (SOURCE[cursor] == "}")
        cursor += 1
    return SOURCE[start:cursor].replace("private ", "")


STUBS = r'''
import Foundation
final class SettingsManager {
    static let shared = SettingsManager()
    var language: AppLanguage = .english
}
enum DshVersionControllerError: Error { case cancelled }
final class ServiceManager {
    static var environment: [String: String] = [:]
    static func commandEnvironment() -> [String: String] { environment }
    var snapshot = ServiceSnapshot(phase: .running, port: 3080, pid: 42, startedAt: nil,
        dshPath: nil, dshVersion: nil, message: nil, isManaged: true, runningDshVersion: "1.0.0")
    var dshDetectionComplete = false
    var environmentDiagnostics: EnvironmentDiagnostics?
    var dshDetectionInFlight = false
    var dshRecheckRequested = false
    var pendingDshDetections: [(Bool) -> Void] = []
    var publishedVersions: [String] = []
    func updateSnapshot(_ mutation: (inout ServiceSnapshot) -> Void) {
        mutation(&snapshot)
        if dshDetectionComplete, let version = snapshot.dshVersion { publishedVersions.append(version) }
    }
    DETECTION
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: " + message) }
}
func pump(until condition: () -> Bool, timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    expect(condition(), "fixture deadline exceeded")
}
'''

CHECKS = r'''
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let bin = root.appendingPathComponent("first bin")
let second = root.appendingPathComponent("second")
let env = ["PATH": "relative::\(bin.path):\(second.path)"]
expect(EnvironmentDiagnostics.findExecutable(named: "dsh", environment: env) == bin.appendingPathComponent("dsh").path,
       "PATH order, empty/relative entries, or paths with spaces")
expect(EnvironmentDiagnostics.findExecutable(named: "directory", environment: env) == nil, "directory counted as command")
expect(EnvironmentDiagnostics.findExecutable(named: "not-executable", environment: env) == nil, "non-executable counted as command")
let inspection = EnvironmentDiagnostics.inspect(environment: env)
expect(inspection.dsh.version == "1.2.3-alpha.1+build", "semver/warning parsing")
expect(inspection.node.version == "v24.1.0" && inspection.npm.version == "11.0.0", "node/npm version detection")
expect(inspection.report.contains(bin.path) && inspection.report.contains(env["PATH"]!), "report lacks paths")
for command in ["nonzero", "invalid"] {
    expect(EnvironmentDiagnostics.version(at: bin.appendingPathComponent(command).path, environment: env) == nil,
           "failed/invalid command became a version: \(command)")
}
for command in ["hang", "noise"] {
    let start = Date()
    expect(EnvironmentDiagnostics.version(at: bin.appendingPathComponent(command).path, environment: env) == nil,
           "hanging/noisy command became a version")
    expect(Date().timeIntervalSince(start) < 6, "unbounded command \(command)")
}
print("PASS command inspection: PATH precedence, executable checks, valid/invalid/nonzero versions, hang and continuous output deadlines")

var snapshot = ServiceSnapshot(phase: .running, port: 3080, pid: 42, startedAt: nil,
    dshPath: inspection.dsh.path, dshVersion: "2.0.0", message: nil, isManaged: true,
    runningDshVersion: "1.0.0")
for language: AppLanguage in [.english, .chinese] {
    Localization.shared.apply(language: language)
    let restart = inspection.findings(for: snapshot)
    expect(restart.contains(L(.diagnosticsRestartAdvice, ["running": "1.0.0", "installed": "2.0.0"])), "restart advice")
    snapshot.isManaged = false
    snapshot.runningDshVersion = nil
    expect(inspection.findings(for: snapshot).contains(L(.diagnosticsUnknownVersion)), "unknown version advice")
    snapshot.phase = .portConflict
    expect(inspection.findings(for: snapshot).contains(L(.diagnosticsPortAdvice, ["port": "3080"])), "port advice")
    let missing = EnvironmentDiagnostics(dsh: CommandDiagnostic(path: nil, version: nil),
        node: CommandDiagnostic(path: nil, version: nil), npm: CommandDiagnostic(path: "/fake/npm", version: nil), searchPath: "")
    let missingFindings = missing.findings(for: snapshot)
    expect(missingFindings.contains(L(.diagnosticsCommandMissing, ["command": "Node"])), "missing command advice")
    expect(missingFindings.contains(L(.diagnosticsCommandFailed, ["command": "npm"])), "failed command advice")
    expect(missingFindings.contains(L(.diagnosticsNodeAdvice)), "Node/npm recovery advice")
    snapshot.phase = .running
    snapshot.isManaged = true
    snapshot.runningDshVersion = "1.0.0"
}
print("PASS localized findings: missing/failing commands, Node/npm recovery, occupied port, unknown/running/installed versions")

let manager = ServiceManager()
ServiceManager.environment = ["PATH": second.path, "FIXTURE_VERSION": root.appendingPathComponent("version").path,
                              "FIXTURE_STAGE": root.appendingPathComponent("stage").path]
var callbacks: [String] = []
manager.detectDshInstallation { found in
    expect(found, "first completion lost command")
    callbacks.append(manager.snapshot.dshVersion ?? "nil")
}
pump(until: { FileManager.default.fileExists(atPath: root.appendingPathComponent("stage").path) }, timeout: 3)
try "2.0.0\n".write(to: root.appendingPathComponent("version"), atomically: true, encoding: .utf8)
manager.detectDshInstallation { found in
    expect(found, "second completion lost command")
    callbacks.append(manager.snapshot.dshVersion ?? "nil")
}
pump(until: { callbacks.count == 2 }, timeout: 15)
expect(callbacks == ["2.0.0", "2.0.0"], "pending completion saw stale inspection")
expect(manager.publishedVersions == ["2.0.0"], "old inspection overwrote installation-triggered refresh")
expect(manager.snapshot.runningDshVersion == "1.0.0" && manager.snapshot.needsVersionRestart,
       "environment inspection rewrote running service version")
print("PASS actual detection: coalesced recheck, latest installed version only, every completion delivered, running version preserved")
'''

with tempfile.TemporaryDirectory(prefix="dsh-environment-check-") as directory:
    work = Path(directory)
    first = work / "first bin"
    second = work / "second"
    first.mkdir()
    second.mkdir()
    scripts = {
        "dsh": "printf 'startup warning\\n1.2.3-alpha.1+build\\n'",
        "node": "printf 'v24.1.0\\n'",
        "npm": "printf '11.0.0\\n'",
        "nonzero": "printf '1.0.0\\n'; exit 1",
        "invalid": "printf 'this is not a version\\n'",
        "hang": "/bin/sleep 30",
        "noise": "while :; do printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; done",
    }
    for name, body in scripts.items():
        script = first / name
        script.write_text("#!/bin/sh\n" + body + "\n")
        script.chmod(0o700)
    (first / "directory").mkdir()
    (first / "not-executable").write_text("not executable")
    for name in ("node", "npm"):
        script = second / name
        script.write_text("#!/bin/sh\nprintf '1.0.0\\n'\n")
        script.chmod(0o700)
    script = second / "dsh"
    script.write_text('#!/bin/sh\nIFS= read -r version < "$FIXTURE_VERSION"\n: > "$FIXTURE_STAGE"\n/bin/sleep 0.3\nprintf "%s\\n" "$version"\n')
    script.chmod(0o700)
    (work / "version").write_text("1.0.0\n")
    cache = work / "module-cache"
    cache.mkdir()
    models = SOURCE[:SOURCE.index("final class ServiceManager {")]
    (work / "Models.swift").write_text(models)
    (work / "Fixture.swift").write_text(STUBS.replace("DETECTION", member("func detectDshInstallation(completion:")))
    (work / "main.swift").write_text("import Foundation\n" + CHECKS)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cache), SWIFT_MODULECACHE_PATH=str(cache))
    binary = work / "environment-check"
    subprocess.run(["swiftc", "-Onone", "-module-cache-path", str(cache),
                    str(work / "Models.swift"), str(work / "Fixture.swift"), str(work / "main.swift"),
                    str(ROOT / "Sources/Localization.swift"), str(ROOT / "Sources/EnvironmentDiagnostics.swift"),
                    str(ROOT / "Sources/InstallProcess.swift"), "-o", str(binary)],
                   env=env, check=True, timeout=120)
    subprocess.run([str(binary), str(work)], env=env, check=True, timeout=60)
