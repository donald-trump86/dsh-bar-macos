#!/usr/bin/env python3
"""Exercise the actual hotkey manager with isolated Carbon/workspace substitutes."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent

STUBS = r'''
import Foundation

typealias OSStatus = Int32
typealias OSType = UInt32
typealias EventHotKeyRef = Int
typealias EventHandlerRef = Int
typealias EventParamName = UInt32
typealias EventParamType = UInt32
typealias EventHandlerUPP = (Int?, Int?, UnsafeMutableRawPointer?) -> OSStatus
let noErr: OSStatus = 0
let paramErr: OSStatus = -50
let eventNotHandledErr = -9874
let kEventClassKeyboard = 1
let kEventHotKeyPressed = 2
let kEventParamDirectObject = 3
let typeEventHotKeyID = 4
struct EventHotKeyID { var signature: OSType = 0; var id: UInt32 = 0 }
struct EventTypeSpec { var eventClass: OSType; var eventKind: UInt32 }

final class NSWorkspace {
    static let shared = NSWorkspace()
    static let didWakeNotification = Notification.Name("probe.wake")
    static let sessionDidBecomeActiveNotification = Notification.Name("probe.session")
    let notificationCenter = NotificationCenter()
}
var installStatus: OSStatus = -100
var registrationStatus: OSStatus = 0
var omitHandler = false
var omitHotKey = false
var installs = 0
var registerCalls = 0
var unregistrations = 0
var nextReference = 0
var handlers: [Int: EventHandlerUPP] = [:]
var keys: [Int: (UInt32, UInt32, UInt32)] = [:]
var deliveredID: UInt32 = 1
func GetEventDispatcherTarget() -> Int { 0 }
func InstallEventHandler(_ target: Int, _ callback: @escaping EventHandlerUPP,
                         _ count: Int, _ event: inout EventTypeSpec,
                         _ data: UnsafeMutableRawPointer?, _ ref: inout EventHandlerRef?) -> OSStatus {
    installs += 1
    guard installStatus == noErr else { return installStatus }
    if !omitHandler { nextReference += 1; ref = nextReference; handlers[nextReference] = callback }
    return noErr
}
@discardableResult func RemoveEventHandler(_ ref: EventHandlerRef) -> OSStatus {
    handlers.removeValue(forKey: ref); return noErr
}
func RegisterEventHotKey(_ key: UInt32, _ modifiers: UInt32, _ id: EventHotKeyID,
                         _ target: Int, _ options: Int, _ ref: inout EventHotKeyRef?) -> OSStatus {
    registerCalls += 1
    guard registrationStatus == noErr else { return registrationStatus }
    if !omitHotKey { nextReference += 1; ref = nextReference; keys[nextReference] = (id.id, key, modifiers) }
    return noErr
}
@discardableResult func UnregisterEventHotKey(_ ref: EventHotKeyRef) -> OSStatus {
    unregistrations += 1; keys.removeValue(forKey: ref); return noErr
}
func GetEventParameter(_ event: Int?, _ name: EventParamName, _ type: EventParamType,
                       _ actualType: UnsafeMutableRawPointer?, _ size: Int,
                       _ actualSize: UnsafeMutableRawPointer?, _ result: inout EventHotKeyID) -> OSStatus {
    result = EventHotKeyID(signature: 0x44534842, id: deliveredID); return noErr
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { print("FAIL \(message)"); exit(1) }
}
func drainMainQueue() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
'''

SCENARIOS = r'''
let manager = HotKeyManager.shared
var actions = 0
manager.register(id: 1, keyCode: 8, modifiers: 9) { actions += 1 }
expect(manager.lastRegistrationStatus == -100, "handler installation error must remain visible")
expect(registerCalls == 0 && keys.isEmpty && handlers.isEmpty, "failed handler must prevent registration")
installStatus = noErr
omitHandler = true
manager.recoverRegistrations()
expect(manager.lastRegistrationStatus != nil && registerCalls == 0, "missing handler reference must prevent registration")
omitHandler = false
manager.recoverRegistrations()
expect(manager.lastRegistrationStatus == nil, "successful recovery clears the error")
expect(keys.count == 1 && handlers.count == 1 && installs == 3, "retry creates one handler and one key")
expect(keys.values.first!.1 == 8 && keys.values.first!.2 == 9, "retry preserves key and modifiers")
_ = handlers.values.first!(nil, nil, nil)
drainMainQueue()
expect(actions == 1, "retry preserves the desired action")

for _ in 0..<3 { manager.recoverRegistrations() }
expect(keys.count == 1 && handlers.count == 1 && installs == 3, "recovery must not duplicate resources")
registrationStatus = -9878
manager.register(id: 1, keyCode: 10, modifiers: 11) { actions += 10 }
expect(manager.lastRegistrationStatus == -9878 && keys.isEmpty, "registration conflict remains visible")
registrationStatus = noErr
manager.recoverRegistrations()
expect(manager.lastRegistrationStatus == nil && keys.count == 1, "conflict stays retryable")
expect(keys.values.first!.1 == 10 && keys.values.first!.2 == 11, "replacement desired configuration retained")
_ = handlers.values.first!(nil, nil, nil)
drainMainQueue()
expect(actions == 11, "replacement desired action retained")

// One successful registration must not hide another desired shortcut's failure.
registrationStatus = -9878
manager.register(id: 2, keyCode: 20, modifiers: 21) {}
registrationStatus = noErr
manager.register(id: 1, keyCode: 10, modifiers: 11) { actions += 10 }
expect(manager.lastRegistrationStatus == -9878, "another shortcut's success must not erase failure")
manager.unregister(id: 2)
expect(manager.lastRegistrationStatus == nil, "removing failed registration clears its error")

registrationStatus = -9878
manager.register(id: 1, keyCode: 12, modifiers: 13) { actions += 100 }
manager.unregister(id: 1)
registrationStatus = noErr
manager.recoverRegistrations()
expect(keys.isEmpty, "unregister after failure must not resurrect the key")
_ = handlers.values.first!(nil, nil, nil)
drainMainQueue()
expect(actions == 11, "unregister after failure must remove desired action")

omitHotKey = true
manager.register(id: 1, keyCode: 14, modifiers: 15) {}
expect(manager.lastRegistrationStatus != nil, "success without a reference is still failure")
omitHotKey = false
manager.recoverRegistrations()
expect(keys.count == 1 && manager.lastRegistrationStatus == nil, "missing reference stays retryable")

manager.startRecoveryMonitoring()
manager.startRecoveryMonitoring()
let beforeWake = registerCalls
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
drainMainQueue()
expect(registerCalls == beforeWake + 1, "wake recovers once despite repeated monitor start")
let beforeSession = registerCalls
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
drainMainQueue()
expect(registerCalls == beforeSession + 1, "session activation recovers the key")
expect(keys.count == 1 && handlers.count == 1, "notifications do not duplicate resources")
manager.stopRecoveryMonitoring()
manager.stopRecoveryMonitoring()
let afterStop = registerCalls
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
drainMainQueue()
expect(registerCalls == afterStop, "stopped monitoring releases both observers")
manager.startRecoveryMonitoring()
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
drainMainQueue()
expect(registerCalls == afterStop + 1, "monitoring can restart without duplicate observers")
manager.stopRecoveryMonitoring()
manager.unregister(id: 1)
expect(keys.isEmpty, "final unregister releases live reference")
print("PASS production hotkey registration failures, retry, action delivery, and workspace observer lifecycle")
'''


def main() -> None:
    production = (ROOT / "Sources/HotKeyManager.swift").read_text()
    production = production.replace("import Foundation", "").replace("import Carbon", "").replace("import AppKit", "")
    with tempfile.TemporaryDirectory(prefix="dshbar-hotkey-recovery-") as directory:
        d = Path(directory)
        source, binary = d / "probe.swift", d / "probe"
        source.write_text(STUBS + production + SCENARIOS)
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(d / "modulecache"))
        subprocess.run(["xcrun", "swiftc", str(source), "-o", str(binary)], env=env, check=True, timeout=120)
        subprocess.run([str(binary)], env=env, check=True, timeout=30)
    app = (ROOT / "Sources/AppDelegate.swift").read_text()
    assert "HotKeyManager.shared.startRecoveryMonitoring()" in app
    assert "HotKeyManager.shared.stopRecoveryMonitoring()" in app
    print("PASS app launch/termination wires shortcut recovery monitoring")


if __name__ == "__main__":
    main()
