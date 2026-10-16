import Foundation
import Carbon
import AppKit

final class HotKeyManager {
    static let shared = HotKeyManager()

    typealias HotKeyAction = () -> Void
    private struct Registration {
        let keyCode: UInt32
        let modifiers: UInt32
        let action: HotKeyAction
    }
    private var registrations: [UInt32: Registration] = [:]
    private var registrationErrors: [UInt32: OSStatus] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var recoveryObservers: [NSObjectProtocol] = []

    /// Includes handler installation errors and failed desired registrations.
    /// Success for one shortcut must not hide another shortcut's failure.
    var lastRegistrationStatus: OSStatus? {
        registrationErrors.keys.sorted().first.flatMap { registrationErrors[$0] }
    }

    private init() {}

    deinit {
        stopRecoveryMonitoring()
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }

    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping HotKeyAction) {
        precondition(Thread.isMainThread)
        unregister(id: id)
        registrations[id] = Registration(keyCode: keyCode, modifiers: modifiers, action: action)
        installRegistration(id: id)
    }

    private func installRegistration(id: UInt32) {
        guard let registration = registrations[id] else { return }
        let handlerStatus = setupEventHandlerIfNeeded()
        guard handlerStatus == noErr else {
            registrationErrors[id] = handlerStatus
            NSLog("[HotKeyManager] Failed to install event handler: error code \(handlerStatus)")
            return
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x44534842), id: id) // 'DSHB'
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            registration.keyCode,
            registration.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr, let ref = hotKeyRef {
            hotKeyRefs[id] = ref
            registrationErrors.removeValue(forKey: id)
        } else {
            if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
            let failure = status == noErr ? OSStatus(paramErr) : status
            registrationErrors[id] = failure
            NSLog("[HotKeyManager] Failed to register hotkey id \(id): error code \(failure)")
        }
    }

    func recoverRegistrations() {
        precondition(Thread.isMainThread)
        for id in registrations.keys.sorted() {
            if let ref = hotKeyRefs.removeValue(forKey: id) {
                UnregisterEventHotKey(ref)
            }
            installRegistration(id: id)
        }
    }

    func startRecoveryMonitoring() {
        precondition(Thread.isMainThread)
        guard recoveryObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            recoveryObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.recoverRegistrations()
            })
        }
    }

    func stopRecoveryMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in recoveryObservers { center.removeObserver(observer) }
        recoveryObservers.removeAll()
    }

    /// Asks the system whether a combination is free, without keeping it.
    ///
    /// The caller must have unregistered this app's own hot key first: the
    /// conflict check is global, so our own registration would answer "taken"
    /// and reject the user for choosing the shortcut they already have.
    func isAvailable(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let probeID = EventHotKeyID(signature: OSType(0x44534842), id: 0xFFFF_FFFF)
        var probeRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            probeID,
            GetEventDispatcherTarget(),
            0,
            &probeRef
        )
        defer {
            if let probeRef { UnregisterEventHotKey(probeRef) }
        }
        return status == noErr
    }
    
    func unregister(id: UInt32) {
        precondition(Thread.isMainThread)
        if let ref = hotKeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        registrations.removeValue(forKey: id)
        registrationErrors.removeValue(forKey: id)
    }
    
    private func setupEventHandlerIfNeeded() -> OSStatus {
        guard eventHandler == nil else { return noErr }
        
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        let handlerCallback: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            
            if status == noErr {
                DispatchQueue.main.async {
                    HotKeyManager.shared.registrations[hotKeyID.id]?.action()
                }
                return noErr
            }
            return OSStatus(eventNotHandledErr)
        }
        
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            handlerCallback,
            1,
            &eventType,
            nil,
            &eventHandler
        )
        
        if status == noErr, eventHandler != nil {
            return noErr
        }
        if let handler = eventHandler { RemoveEventHandler(handler) }
        eventHandler = nil
        return status == noErr ? OSStatus(paramErr) : status
    }
}
