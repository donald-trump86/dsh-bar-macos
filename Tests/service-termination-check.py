#!/usr/bin/env python3
"""Run extracted lifecycle/quit/relaunch code without real services or updates."""
import os
from pathlib import Path
import re
import runpy
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
extract = runpy.run_path(str(ROOT / "Tests/update-availability-check.py"))["method"]


def main() -> None:
    source = (ROOT / "Sources/ServiceManager.swift").read_text()
    delegate = (ROOT / "Sources/AppDelegate.swift").read_text()
    updater = (ROOT / "Sources/UpdateManager.swift").read_text()
    idle = extract(source, "func performWhenLifecycleIdle(_ action: @escaping () -> Void)")
    schedule = extract(source, "private func scheduleLifecycleIdleActions()")
    update = extract(source, "private func updateSnapshot(_ mutation: (inout ServiceSnapshot) -> Void)")
    prepare = extract(source, "func prepareForTermination()")
    stop = extract(source, "func stopServiceForQuit(completion: @escaping (Bool, String?) -> Void)")
    terminate = extract(delegate, "func applicationShouldTerminate(_ sender: NSApplication)")
    postpone = extract(updater, "func updater(")
    fields = "\n".join(re.findall(r"^    private var lifecycleIdle(?:Actions|DrainScheduled)[^\n]+", source, re.M))
    quit_fields = "\n".join(re.findall(r"^    private var (?:pendingQuitStopsService|terminationReplyPending)[^\n]+", delegate, re.M))
    assert len(fields.splitlines()) == 2, "Missing actual idle-queue state"
    assert len(quit_fields.splitlines()) == 2, "Missing actual one-reply guard"
    launch = extract(source, "private func launchAndWait(completion: @escaping (Bool, String?) -> Void)")
    assert launch.index("self.saveManagedRecord(record)") < launch.index("$0.phase = .running")
    assert "scheduleLifecycleIdleActions()" in update
    assert "SPUUpdaterDelegate" in updater and "updaterDelegate: self" in updater

    fixture = r'''
import Foundation
PHASE
struct ServiceSnapshot {
    var phase: ServicePhase = .stopped
    var isManaged = true
    var isRunning: Bool { phase == .running }
}
final class ServiceManager {
    static var shared = ServiceManager()
    var snapshot = ServiceSnapshot()
    var statusObservers: [UUID: (ServiceSnapshot) -> Void] = [:]
    var autoRestartWorkItem: DispatchWorkItem?
    var monitorStops = 0
    var stopCalls = 0
    var identitySaved = false
    var cleaned = false
FIELDS
IDLE
SCHEDULE
UPDATE
PREPARE
STOP
    func setPhase(_ phase: ServicePhase) { updateSnapshot { $0.phase = phase } }
    func stopMonitoring() { monitorStops += 1 }
    func cancelPendingAutoRestart() { autoRestartWorkItem?.cancel(); autoRestartWorkItem = nil }
    func stopService(completion: @escaping (Bool, String?) -> Void) {
        expect(!snapshot.phase.isBusy, "stop must wait for launch/restart")
        stopCalls += 1
        setPhase(.stopping)
        DispatchQueue.main.async {
            self.identitySaved = false
            self.setPhase(.stopped)
            completion(true, nil)
        }
    }
    func queueDrained() -> Bool { lifecycleIdleActions.isEmpty && !lifecycleIdleDrainScheduled }
}
final class DshVersionController {
    static let shared = DshVersionController()
    var isInstalling = false
    var cancelCalls = 0
    var waiters: [() -> Void] = []
    func cancelInstallForTermination(completion: @escaping () -> Void) {
        cancelCalls += 1
        if isInstalling { waiters.append(completion) }
        else { DispatchQueue.main.async(execute: completion) }
    }
    func finishCleanup() {
        isInstalling = false
        let pending = waiters
        waiters = []
        pending.forEach { $0() }
    }
}
final class HotKeyManager {
    static let shared = HotKeyManager()
    var monitorStops = 0
    func stopRecoveryMonitoring() { monitorStops += 1 }
}
final class NSApplication {
    enum TerminateReply { case terminateNow, terminateLater, terminateCancel }
    static let shared = NSApplication()
    var replies = 0
    func reply(toApplicationShouldTerminate: Bool) {
        expect(toApplicationShouldTerminate)
        expect(!ServiceManager.shared.snapshot.phase.isBusy, "termination replied during lifecycle")
        expect(!DshVersionController.shared.isInstalling, "termination replied before installation cleanup")
        expect(HotKeyManager.shared.monitorStops == 1, "termination must release shortcut recovery once")
        replies += 1
    }
}
final class DelegateProbe {
QUIT_FIELDS
TERMINATE
    func requestStop() { pendingQuitStopsService = true }
}
final class SPUUpdater {}
final class SUAppcastItem {}
final class UpdateProbe {
POSTPONE
}
func expect(_ condition: Bool, _ message: String = "termination assertion failed") {
    if !condition { print("FAIL \(message)"); exit(1) }
}
func drain() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025)) }
func reset(_ phase: ServicePhase = .stopped) -> ServiceManager {
    let service = ServiceManager()
    ServiceManager.shared = service
    service.setPhase(phase)
    NSApplication.shared.replies = 0
    HotKeyManager.shared.monitorStops = 0
    return service
}
// Idle callbacks must be asynchronous and exactly once.
var service = reset()
var calls = 0
service.performWhenLifecycleIdle { calls += 1 }
expect(calls == 0)
drain()
expect(calls == 1 && service.queueDrained())
service.setPhase(.running)
drain()
expect(calls == 1)
// Every active lifecycle waits for identity save or failure cleanup.
for phase in [ServicePhase.starting, .stopping, .restarting] {
    service = reset(phase)
    calls = 0
    let current = service
    current.performWhenLifecycleIdle { expect(current.identitySaved); calls += 1 }
    drain()
    expect(calls == 0)
    current.identitySaved = true
    current.setPhase(.running)
    drain()
    expect(calls == 1 && current.queueDrained())
}
service = reset(.starting)
calls = 0
let failed = service
failed.performWhenLifecycleIdle { expect(failed.cleaned); calls += 1 }
failed.cleaned = true
failed.setPhase(.error)
drain()
expect(calls == 1)
// Recheck at dispatch time; a previously idle service may have started work.
service = reset()
calls = 0
service.performWhenLifecycleIdle { calls += 1 }
service.setPhase(.starting)
drain()
expect(calls == 0)
service.setPhase(.error)
drain()
expect(calls == 1)
// A callback that starts another lifecycle pauses the FIFO, including reentry.
service = reset()
let reentrant = service
var order: [Int] = []
reentrant.performWhenLifecycleIdle {
    order.append(1)
    reentrant.performWhenLifecycleIdle { order.append(3) }
    reentrant.setPhase(.restarting)
}
reentrant.performWhenLifecycleIdle { order.append(2) }
drain()
expect(order == [1])
reentrant.setPhase(.running)
drain()
expect(order == [1, 2, 3] && reentrant.queueDrained())
// Snapshot observers can start work before the idle gate schedules its drain.
service = reset(.starting)
let observed = service
let token = UUID()
observed.statusObservers[token] = { snapshot in
    if snapshot.phase == .running {
        observed.statusObservers.removeValue(forKey: token)
        observed.setPhase(.restarting)
    }
}
calls = 0
observed.performWhenLifecycleIdle { calls += 1 }
observed.setPhase(.running)
drain()
expect(calls == 0)
observed.setPhase(.error)
drain()
expect(calls == 1)
print("PASS actual idle gate: success, failure, reentry, dispatch recheck and FIFO")
// Real delegate body: ordinary quit preserves the successful managed service.
for phase in [ServicePhase.starting, .restarting] {
    service = reset(phase)
    let quit = DelegateProbe()
    expect(quit.applicationShouldTerminate(.shared) == .terminateLater)
    expect(quit.applicationShouldTerminate(.shared) == .terminateLater)
    drain()
    expect(NSApplication.shared.replies == 0 && service.stopCalls == 0)
    expect(HotKeyManager.shared.monitorStops == 0, "shortcut recovery must stay active until final reply")
    service.identitySaved = true
    service.setPhase(.running)
    drain()
    expect(NSApplication.shared.replies == 1 && service.identitySaved)
    expect(service.monitorStops == 1 && service.stopCalls == 0)
}
// Finishing an already-requested stop must not trigger a second stop.
service = reset(.stopping)
let stoppingQuit = DelegateProbe()
_ = stoppingQuit.applicationShouldTerminate(.shared)
drain()
expect(NSApplication.shared.replies == 0)
service.setPhase(.stopped)
drain()
expect(NSApplication.shared.replies == 1 && service.stopCalls == 0)
service = reset(.starting)
let stopQuit = DelegateProbe()
stopQuit.requestStop()
expect(stopQuit.applicationShouldTerminate(.shared) == .terminateLater)
drain()
expect(service.stopCalls == 0 && NSApplication.shared.replies == 0)
service.identitySaved = true
service.setPhase(.running)
drain()
expect(service.stopCalls == 1 && NSApplication.shared.replies == 1 && !service.identitySaved)
service = reset(.running)
service.snapshot.isManaged = false
let externalQuit = DelegateProbe()
externalQuit.requestStop()
_ = externalQuit.applicationShouldTerminate(.shared)
drain()
expect(service.stopCalls == 0 && NSApplication.shared.replies == 1)
service = reset(.starting)
let failureQuit = DelegateProbe()
_ = failureQuit.applicationShouldTerminate(.shared)
service.cleaned = true
service.setPhase(.error)
drain()
expect(NSApplication.shared.replies == 1 && service.stopCalls == 0)
print("PASS actual quit delegate: delayed reply, repeated requests, owned stop and external safety")
// Quit must join installer cleanup before handling the service or replying.
service = reset(.running)
let installerQuit = DelegateProbe()
let installer = DshVersionController.shared
installer.isInstalling = true
let cancelCalls = installer.cancelCalls
expect(installerQuit.applicationShouldTerminate(.shared) == .terminateLater)
expect(installerQuit.applicationShouldTerminate(.shared) == .terminateLater)
drain()
expect(installer.cancelCalls == cancelCalls + 1, "repeated quit requested duplicate cleanup")
expect(NSApplication.shared.replies == 0 && service.monitorStops == 0,
       "quit finalized before installation cleanup")
installer.finishCleanup()
drain()
expect(NSApplication.shared.replies == 1 && service.stopCalls == 0,
       "quit did not complete after cleanup or stopped healthy service")
print("PASS actual quit gate joins installation cleanup before service handling")
// Real Sparkle hook body: delay only while lifecycle is active.
service = reset(.running)
let updateProbe = UpdateProbe()
var installs = 0
expect(!updateProbe.updater(SPUUpdater(), shouldPostponeRelaunchForUpdate: SUAppcastItem(), untilInvokingBlock: { installs += 1 }))
expect(installs == 0)
service = reset(.restarting)
expect(updateProbe.updater(SPUUpdater(), shouldPostponeRelaunchForUpdate: SUAppcastItem(), untilInvokingBlock: { installs += 1 }))
drain()
expect(installs == 0)
service.identitySaved = true
service.setPhase(.running)
drain()
expect(installs == 1 && service.identitySaved && service.stopCalls == 0)
print("PASS actual Sparkle hook: postponement settles lifecycle without stopping healthy service")
'''
    replacements = {
        "PHASE": extract(source, "enum ServicePhase: String, Equatable"),
        "FIELDS": fields, "IDLE": idle, "SCHEDULE": schedule, "UPDATE": update,
        "PREPARE": prepare, "STOP": stop, "QUIT_FIELDS": quit_fields,
        "TERMINATE": terminate, "POSTPONE": postpone,
    }
    for marker, body in replacements.items():
        fixture = fixture.replace("\n" + marker + "\n", "\n" + body + "\n")
    with tempfile.TemporaryDirectory(prefix="dshbar-termination-") as directory:
        d = Path(directory)
        swift, binary = d / "probe.swift", d / "probe"
        swift.write_text(fixture)
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(d / "modulecache"))
        subprocess.run(["xcrun", "swiftc", str(swift), "-o", str(binary)],
                       env=env, check=True, timeout=120)
        subprocess.run([str(binary)], env=env, check=True, timeout=30)


if __name__ == "__main__":
    main()
