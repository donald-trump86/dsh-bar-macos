import Foundation
import Carbon
import AppKit

final class HotKeyManager {
    static let shared = HotKeyManager()

    typealias HotKeyAction = () -> Void
    private var actions: [UInt32: HotKeyAction] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerInstalled = false
    private var eventHandler: EventHandlerRef?

    /// `RegisterEventHotKey` fails when another app already owns the
    /// combination, and the UI used to swallow that — the preference showed a
    /// hotkey that was never live. `OSStatus` is nil while registration is
    /// known good; anything else means the shortcut is dead.
    private(set) var lastRegistrationStatus: OSStatus?

    private init() {}

    deinit {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }

    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping HotKeyAction) {
        unregister(id: id)
        setupEventHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x44534842), id: id) // 'DSHB'
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr, let ref = hotKeyRef {
            actions[id] = action
            hotKeyRefs[id] = ref
            lastRegistrationStatus = nil
        } else {
            lastRegistrationStatus = status
            NSLog("[HotKeyManager] Failed to register hotkey id \(id): error code \(status)")
        }
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
        if let ref = hotKeyRefs[id] {
            UnregisterEventHotKey(ref)
            hotKeyRefs.removeValue(forKey: id)
            actions.removeValue(forKey: id)
        }
    }
    
    private func setupEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        
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
                    HotKeyManager.shared.actions[hotKeyID.id]?()
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
        
        if status == noErr {
            eventHandlerInstalled = true
        }
    }
}
