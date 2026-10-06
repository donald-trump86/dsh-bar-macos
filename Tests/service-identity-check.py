#!/usr/bin/env python3
"""Exercise production probe/ownership/recovery code with isolated I/O seams.

No live Web, auth logs or home-directory state are touched. HTTP transport,
TCP/lsof/ps observations and the eventual recovery launch are controlled; the
status, ownership, callback and recovery decisions are extracted verbatim.
"""
from pathlib import Path
import re
import subprocess
import tempfile

REPO = Path(__file__).resolve().parent.parent
SOURCE = (REPO / "Sources/ServiceManager.swift").read_text()


def extract(marker, indent="    "):
    start = SOURCE.index(indent + marker)
    end = SOURCE.index("\n" + indent + "}", start) + len(indent) + 2
    return SOURCE[start:end]


models = extract("enum ServicePhase:", "") + "\n" + extract("struct ServiceSnapshot:", "")
members = [extract(marker) for marker in (
    "private enum ProbeResult", "private enum StopResult",
    "private struct ManagedServiceRecord", "private func preflightRestart(",
    "private func updateSnapshot(", "func checkStatus(", "private func probe(",
    "private func applyProbe(", "private func saveManagedRecord(",
    "private func clearManagedRecord(", "private func finishStop(",
    "func stopService(", "private func handleUnexpectedExit(",
    "private func scheduleAutoRestart(", "private func pruneAutoRestartAttempts(",
    "func cancelPendingAutoRestart(", "func acknowledgeUnexpectedExit(",
    "private func beginIntentionalStop(", "private func endIntentionalStop(",
    "func startService(", "private func beginLaunch(", "private func launchAndWait(",
    "var baseUrl:", "func openBrowser(", "func restartService(",
)]
# Optional only to allow a red run against the pre-fix production source.
if "    private func matchesManagedIdentity(" in SOURCE:
    members.append(extract("private func matchesManagedIdentity("))
constants = "\n".join(re.findall(
    r"^    (?:private static let harnessMarkers|static let autoRestart(?:MaxAttempts|Window|Backoff)).*$",
    SOURCE, re.M))
# The harness exposes members to assertions; function bodies are unchanged.
members = "\n".join(members).replace("private ", "")
keys = sorted(set(re.findall(r"L\(\.(\w+)", members)))
header = r'''import Foundation
import Darwin
final class SettingsManager {
    static let shared = SettingsManager()
    var port = 3080
    var autoRestartEnabled = true
}
final class NSWorkspace {
    static let shared = NSWorkspace()
    var lastURL: URL?
    func open(_ url: URL) { lastURL = url }
}
final class ServiceNotifier {
    static let shared = ServiceNotifier()
    var exits = 0
    var recoveries = 0
    func requestAuthorizationIfNeeded() {}
    func notifyUnexpectedExit(pid: Int32?, port: Int) { exits += 1 }
    func notifyGaveUp() {}
    func notifyAutoRestarted(attempt: Int) { recoveries += 1 }
}
'''
transport = r'''
final class ProbeTransport: URLProtocol {
    static var body: String? = nil
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let body = Self.body {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        }
    }
    override func stopLoading() {}
}
final class LogWriterProcess {
    var authenticatedURL: URL? = nil
}
final class ServiceManager {
    static let installCommand = "unused"
    static let dshDirectoryURL = URL(fileURLWithPath: CommandLine.arguments[1])
    static var managedRecordURL: URL { dshDirectoryURL.appendingPathComponent("record.json") }
    var pidFileURL: URL { Self.dshDirectoryURL.appendingPathComponent("pid") }
    var port: Int { SettingsManager.shared.port }
    var snapshot = ServiceSnapshot(phase: .checking, port: 3080, pid: nil,
        startedAt: nil, dshPath: nil, dshVersion: nil, message: nil, isManaged: false)
    var statusObservers: [UUID: (ServiceSnapshot) -> Void] = [:]
    var checkInFlight = false
    var pendingCheckCompletions: [(Bool) -> Void] = []
    var consecutiveProbeMisses = 0
    var authenticatedURL: URL?
    var managedRecord: ManagedServiceRecord?
    var intentionalStopInFlight = false
    var lastUnexpectedExit: Date?
    var lastUnexpectedExitPID: Int32?
    var recoverySuspended = false
    var autoRestartAttempts: [Date] = []
    var autoRestartWorkItem: DispatchWorkItem?
    var autoRestartEnabled: Bool { SettingsManager.shared.autoRestartEnabled }
    var launchedProcess: Process?
    var launchedLogWriter: LogWriterProcess?
    var listening = true
    var observedPID: Int32? = 1234
    var observedStart: Date? = Date(timeIntervalSince1970: 1_000_000)
    var launchCount = 0
    var stopCount = 0
    var stopResult: StopResult = .none
    let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProbeTransport.self]
        session = URLSession(configuration: config)
    }
    func isPortListening(_ port: Int) -> Bool { listening }
    func listenerPID(on port: Int) -> Int32? { observedPID }
    func processStartDate(pid: Int32) -> Date? { observedStart }
    func findDshBinary() -> String? { "/fake/dsh" }
    func runStopScript(port: Int) -> StopResult { stopCount += 1; return stopResult }
    func readDshVersion(at path: String) -> String? { "test" }
    func launchProcess(path: String, port: Int) throws -> (Process, LogWriterProcess) {
        launchCount += 1
        throw NSError(domain: "IsolatedTestLaunch", code: 1)
    }
    static func terminateFailedLaunch(_ process: Process) {
        expect(false, "test unexpectedly reached real launch cleanup")
    }
'''
checks = r'''
func expect(_ value: Bool, _ message: String) {
    if !value {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}
func pump(until condition: () -> Bool, seconds: TimeInterval = 5) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    expect(condition(), "asynchronous status/recovery callback timed out")
}
let ownedPID: Int32 = 1234
let ownedStart = Date(timeIntervalSince1970: 1_000_000)
let auth = URL(string: "http://127.0.0.1:3080/?token=synthetic-test-only")!
func fixture() -> ServiceManager {
    let manager = ServiceManager()
    manager.saveManagedRecord(.init(pid: ownedPID, port: 3080,
                                    startedAt: ownedStart, executablePath: "/fake/dsh"))
    try! "1234".write(to: manager.pidFileURL, atomically: true, encoding: .utf8)
    manager.authenticatedURL = auth
    manager.snapshot = .init(phase: .running, port: 3080, pid: ownedPID,
        startedAt: ownedStart, dshPath: "/fake/dsh", dshVersion: nil,
        message: nil, isManaged: true)
    ProbeTransport.body = nil
    return manager
}
func poll(_ manager: ServiceManager, expectedHealthy: Bool) {
    var completions: [Bool] = []
    manager.checkStatus { completions.append($0) }
    manager.checkStatus { completions.append($0) }
    pump(until: { completions.count == 2 })
    expect(completions == [expectedHealthy, expectedHealthy], "coalesced callbacks misreported HTTP health")
}
func retained(_ manager: ServiceManager) {
    expect(manager.managedRecord?.pid == ownedPID, "HTTP failure erased owned record")
    expect(manager.authenticatedURL == auth, "HTTP failure erased owned auth URL")
    expect(FileManager.default.fileExists(atPath: ServiceManager.managedRecordURL.path),
           "HTTP failure erased persisted record")
    expect(FileManager.default.fileExists(atPath: manager.pidFileURL.path), "HTTP failure erased PID file")
}
func cleared(_ manager: ServiceManager) {
    expect(manager.managedRecord == nil && manager.authenticatedURL == nil,
           "conclusive identity change retained record/auth")
    expect(!FileManager.default.fileExists(atPath: ServiceManager.managedRecordURL.path),
           "conclusive identity change retained persisted record")
    expect(!FileManager.default.fileExists(atPath: manager.pidFileURL.path),
           "conclusive identity change retained PID file")
    expect(!manager.snapshot.isManaged, "identity mismatch claimed management")
}
let manager = fixture()
var observed: [ServiceSnapshot] = []
manager.statusObservers[UUID()] = { observed.append($0) }
poll(manager, expectedHealthy: false)
retained(manager)
expect(manager.snapshot.phase == .portConflict && !manager.snapshot.isManaged,
       "HTTP failure falsely claimed healthy/managed service or free port")
expect(observed.last?.phase == .portConflict && observed.last?.isManaged == false,
       "observer did not receive truthful unhealthy status")
expect(manager.lastUnexpectedExit == nil && manager.launchCount == 0,
       "temporary HTTP failure was treated as crash")
// Repeated misses must not turn a listening port into stopped/free.
poll(manager, expectedHealthy: false)
retained(manager)
ProbeTransport.body = "<script>window.__DSH_BOOT__ = {};</script>"
poll(manager, expectedHealthy: true)
expect(manager.snapshot.isRunning && manager.snapshot.isManaged, "healthy same PID was permanently external")
retained(manager)
manager.listening = false
poll(manager, expectedHealthy: false) // Existing one-miss debounce.
expect(manager.snapshot.isRunning && manager.managedRecord != nil, "debounce disappeared")
poll(manager, expectedHealthy: false)
expect(manager.snapshot.phase == .stopped && manager.managedRecord == nil,
       "actual exit did not release owned record")
expect(manager.lastUnexpectedExitPID == ownedPID && ServiceNotifier.shared.exits == 1,
       "actual exit lost owned crash attribution")
pump(until: { manager.snapshot.phase == .error && manager.launchCount == 1 })
expect(manager.autoRestartAttempts.count == 2 && manager.lastUnexpectedExit != nil,
       "actual exit did not run recovery or preserve notice")
expect(manager.authenticatedURL == nil, "real new launch failure retained stale auth")
manager.cancelPendingAutoRestart()
print("PASS HTTP failure -> retained record/auth -> healthy managed -> actual exit/recovery")

for healthy in [false, true] {
    for reused in [false, true] {
        let changed = fixture()
        ProbeTransport.body = healthy ? "DeepSeek Harness" : nil
        changed.observedPID = reused ? ownedPID : 9999
        changed.observedStart = reused ? ownedStart.addingTimeInterval(5) : ownedStart
        poll(changed, expectedHealthy: healthy)
        cleared(changed)
        changed.listening = false
        poll(changed, expectedHealthy: false)
        if changed.snapshot.isRunning { poll(changed, expectedHealthy: false) }
        expect(changed.lastUnexpectedExit == nil && changed.launchCount == 0,
               "different/reused process was auto-recovered as ours")
    }
}
print("PASS changed PID and >=5s reused start time clear identity on unhealthy and healthy probes")

for missingPID in [false, true] {
    let uncertain = fixture()
    uncertain.observedPID = missingPID ? nil : ownedPID
    uncertain.observedStart = nil
    poll(uncertain, expectedHealthy: false)
    retained(uncertain)
    ProbeTransport.body = "dsh web"
    poll(uncertain, expectedHealthy: true)
    retained(uncertain)
    expect(!uncertain.snapshot.isManaged, "missing PID/start fingerprint falsely claimed management")
    uncertain.stopService { success, _ in expect(!success, "unverified process stop was allowed") }
    expect(uncertain.stopCount == 0, "unverified identity reached stop script")
    uncertain.observedPID = ownedPID
    uncertain.observedStart = ownedStart
    poll(uncertain, expectedHealthy: true)
    expect(uncertain.snapshot.isManaged, "restored fingerprint could not re-recognize management")
}
print("PASS inconclusive PID/start retains identity without granting management/control")

for missingPID in [false, true] {
    let uncertainExit = fixture()
    uncertainExit.observedPID = missingPID ? nil : ownedPID
    uncertainExit.observedStart = nil
    poll(uncertainExit, expectedHealthy: false)
    retained(uncertainExit)
    uncertainExit.listening = false
    poll(uncertainExit, expectedHealthy: false)
    expect(uncertainExit.lastUnexpectedExitPID == ownedPID && uncertainExit.autoRestartWorkItem != nil,
           "inconclusive probe erased identity needed for later exit/recovery")
    uncertainExit.cancelPendingAutoRestart()
}
print("PASS later unavailable after unknown PID/start still attributes and schedules owned recovery")

for pid: Int32? in [nil, 8888] {
    let busy = ServiceManager()
    busy.observedPID = pid
    ProbeTransport.body = nil
    let probe = busy.probe(port: 3081)
    expect(!probe.isHarness, "unrelated busy port answered healthy")
    if case .unavailable = probe { expect(false, "unknown listening port looked free for launch") }
    busy.applyProbe(probe, port: 3081)
    expect(busy.snapshot.phase == .portConflict && !busy.snapshot.isManaged,
           "unrelated busy port did not remain unavailable")
    expect(busy.preflightRestart(currentPort: 3080, targetPort: 3081) != nil,
           "restart preflight accepted unrelated busy target port")
    busy.stopService { success, _ in expect(!success, "foreign process stop was allowed") }
    expect(busy.stopCount == 0, "foreign process reached stop script")
}
print("PASS unrelated/unknown listening ports remain occupied and foreign processes uncontrollable")

let stopping = fixture()
let unresponsive = stopping.probe(port: 3080)
stopping.finishStop(result: .failed("stop failed"), probe: unresponsive, port: 3080) { success, _ in
    expect(!success, "unresponsive live process falsely reported stopped")
}
retained(stopping)
expect(stopping.snapshot.phase == .portConflict && !stopping.snapshot.isManaged,
       "failed stop reported healthy/managed or free")
print("PASS failed stop with same unresponsive listener preserves identity and reports failure")

func startOccupied(_ manager: ServiceManager) {
    var callbacks: [Bool] = []
    manager.startService { success, message in
        callbacks.append(success)
        expect(message != nil, "occupied Start did not explain refusal")
    }
    pump(until: { !callbacks.isEmpty })
    expect(callbacks == [false] && manager.launchCount == 0,
           "occupied Start spawned a second process or misreported callback")
    expect(!manager.snapshot.phase.isBusy, "occupied Start stranded busy phase")
}
for missingPID in [false, true] {
    let occupiedOwned = fixture()
    occupiedOwned.observedPID = missingPID ? nil : ownedPID
    poll(occupiedOwned, expectedHealthy: false)
    startOccupied(occupiedOwned)
    retained(occupiedOwned)
    expect(occupiedOwned.snapshot.phase == .portConflict && !occupiedOwned.snapshot.isManaged,
           "occupied Start falsely granted management/health")
}
for pid: Int32? in [nil, 8888] {
    let occupiedForeign = ServiceManager()
    occupiedForeign.observedPID = pid
    ProbeTransport.body = nil
    startOccupied(occupiedForeign)
    expect(occupiedForeign.snapshot.phase == .portConflict && !occupiedForeign.snapshot.isManaged,
           "foreign occupied Start did not stay conflicted")
}
let healthyExisting = fixture()
ProbeTransport.body = "DeepSeek Harness"
startOccupied(healthyExisting)
retained(healthyExisting)
expect(healthyExisting.snapshot.isManaged && healthyExisting.snapshot.isRunning,
       "healthy existing Start lost verified managed status")
print("PASS real Start/pre-spawn guard refuses occupied ports once, preserves owned auth and resets busy")

for missingPID in [false, true] {
    let privateAuth = fixture()
    privateAuth.observedPID = missingPID ? nil : ownedPID
    privateAuth.observedStart = nil
    poll(privateAuth, expectedHealthy: false)
    privateAuth.openBrowser()
    expect(NSWorkspace.shared.lastURL == privateAuth.baseUrl, "unhealthy listener received retained token")
    ProbeTransport.body = "dsh web"
    poll(privateAuth, expectedHealthy: true)
    privateAuth.openBrowser()
    expect(NSWorkspace.shared.lastURL == privateAuth.baseUrl, "unverified healthy listener received retained token")
    privateAuth.observedPID = ownedPID
    privateAuth.observedStart = ownedStart
    poll(privateAuth, expectedHealthy: true)
    privateAuth.openBrowser()
    expect(NSWorkspace.shared.lastURL == auth, "verified recovery lost retained token")
    privateAuth.authenticatedURL = URL(string: "http://127.0.0.1:3081/?token=wrong-port")!
    privateAuth.openBrowser()
    expect(NSWorkspace.shared.lastURL == privateAuth.baseUrl, "cached credential crossed ports")
}
let lateAuth = fixture()
lateAuth.authenticatedURL = nil
lateAuth.launchedProcess = Process() // Never run: a harmless PID 0 stand-in for our child.
lateAuth.launchedLogWriter = LogWriterProcess()
lateAuth.launchedLogWriter?.authenticatedURL = auth
let childPID = lateAuth.launchedProcess!.processIdentifier
lateAuth.saveManagedRecord(.init(pid: childPID, port: 3080, startedAt: ownedStart, executablePath: "/fake/dsh"))
lateAuth.snapshot.pid = childPID
lateAuth.snapshot.isManaged = false
lateAuth.openBrowser()
expect(NSWorkspace.shared.lastURL == lateAuth.baseUrl, "unverified listener received late launch token")
lateAuth.snapshot.isManaged = true
lateAuth.snapshot.phase = .restarting
lateAuth.openBrowser()
expect(NSWorkspace.shared.lastURL == lateAuth.baseUrl, "busy/stopping identity received late launch token")
lateAuth.snapshot.phase = .running
lateAuth.openBrowser()
expect(NSWorkspace.shared.lastURL == auth, "verified child lost late launch token")
lateAuth.snapshot.pid = childPID + 1
lateAuth.openBrowser()
expect(NSWorkspace.shared.lastURL == lateAuth.baseUrl, "mismatched PID received late launch token")
lateAuth.snapshot.pid = childPID
lateAuth.snapshot.startedAt = ownedStart.addingTimeInterval(5)
lateAuth.openBrowser()
expect(NSWorkspace.shared.lastURL == lateAuth.baseUrl, "mismatched fingerprint received late launch token")
print("PASS retained/late credentials stay private until managed port/PID/start match")

// Exercise actual restart callbacks and open immediately, with no status poll
// between refusal and browser use. Observations stand in for post-stop evidence.
for result: ServiceManager.StopResult in [.failed("synthetic stop failure"), .stopped, .none, .foreign] {
    let cases: [(Int32?, Date?, String?, Bool, Bool)] = [
        (9999, ownedStart, nil, false, true),
        (9999, ownedStart, "dsh web", false, true),
        (ownedPID, ownedStart.addingTimeInterval(5), "dsh web", false, true),
        (nil, nil, nil, false, false),
        (nil, nil, "dsh web", false, false),
        (ownedPID, nil, "dsh web", false, false),
        (ownedPID, ownedStart, nil, false, false),
        (ownedPID, ownedStart, "dsh web", true, false),
    ]
    for (pid, start, body, trusted, changed) in cases {
        let refusing = fixture()
        refusing.stopResult = result
        refusing.observedPID = pid
        refusing.observedStart = start
        ProbeTransport.body = body
        var callbacks: [Bool] = []
        refusing.restartService { success, message in
            callbacks.append(success)
            expect(message != nil, "restart refusal lost explanation")
        }
        expect(refusing.intentionalStopInFlight, "restart did not suppress intentional exit recovery")
        pump(until: { !callbacks.isEmpty })
        refusing.openBrowser() // BEFORE any later poll can reconcile the evidence.
        expect(NSWorkspace.shared.lastURL == (trusted ? auth : refusing.baseUrl),
               "restart refusal sent old auth to replacement/unverified listener")
        expect(callbacks == [false] && refusing.stopCount == 1 && refusing.launchCount == 0,
               "restart refusal callback/control/spawn count was wrong")
        expect(!refusing.intentionalStopInFlight && !refusing.snapshot.phase.isBusy,
               "restart refusal did not reset intentional-stop/busy state")
        expect(refusing.snapshot.isManaged == trusted && refusing.snapshot.pid == pid,
               "restart refusal restored old trust instead of observed identity")
        expect(refusing.snapshot.phase == (body == nil ? .portConflict : .running),
               "restart refusal ignored observed HTTP health")
        expect(refusing.lastUnexpectedExit == nil && refusing.autoRestartWorkItem == nil,
               "restart refusal treated intentional stop as crash")
        if changed { cleared(refusing) } else { retained(refusing) }
    }
}
print("PASS actual restart stopped/none/failed/foreign refuses with reconciled identity and immediate auth safety")
for result: ServiceManager.StopResult in [.failed("synthetic stop failure"), .foreign] {
    let vanished = fixture()
    vanished.listening = false
    vanished.stopResult = result
    var callbacks: [Bool] = []
    vanished.restartService { success, _ in callbacks.append(success) }
    pump(until: { !callbacks.isEmpty })
    vanished.openBrowser()
    expect(callbacks == [false] && vanished.snapshot.phase == .stopped,
           "failed/refused stop ignored observed vacancy")
    expect(!vanished.intentionalStopInFlight && vanished.lastUnexpectedExit == nil && vanished.autoRestartWorkItem == nil,
           "failed/refused intentional stop incorrectly scheduled recovery")
    expect(NSWorkspace.shared.lastURL == vanished.baseUrl && vanished.launchCount == 0,
           "failed/refused stop with vacancy retained auth or launched")
    cleared(vanished)
}
print("PASS failed/foreign restart observed vacancy clears trust without launch or crash recovery")
'''
program = (header + "enum Key: String { case " + ", ".join(keys) + " }\n"
           + "func L(_ key: Key, _ values: [String: String] = [:]) -> String { key.rawValue }\n"
           + models + transport + constants + "\n" + members + "\n}\n"
           + extract("private final class HTTPProbeBox", "") + checks)
# Ignore inherited shared build caches: all products stay in this unique temp root.
with tempfile.TemporaryDirectory(prefix="dsh-service-identity-", dir="/tmp") as temporary:
    root = Path(temporary).resolve()
    assert root.parent == Path("/tmp").resolve() and root.name.startswith("dsh-service-identity-")
    assert REPO not in root.parents, "test cache must stay outside the checkout/build"
    main = root / "main.swift"
    main.write_text(program)
    binary = root / "identity-check"
    subprocess.run(["swiftc", "-Onone", "-module-cache-path", str(root / "modules"),
                    str(main), "-o", str(binary)], check=True, timeout=120)
    state = root / "state"
    state.mkdir()
    subprocess.run([str(binary), str(state)], check=True, timeout=30)
    # Re-verify the exact cleanup target before TemporaryDirectory removes it.
    assert root.resolve() == Path(temporary).resolve() and root.parent == Path("/tmp").resolve()
assert not root.exists(), "temporary test cache was not cleaned up"
print("PASS isolated temporary cache cleaned up")
