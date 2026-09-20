import Foundation
import Carbon
import AppKit

final class HotKeyManager {
    static let shared = HotKeyManager()
    
    typealias HotKeyAction = () -> Void
    private var actions: [UInt32: HotKeyAction] = [:]
    private var eventHandlerInstalled = false
    private var eventHandler: EventHandlerRef?
    
    private init() {}
    
    deinit {
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }
    
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping HotKeyAction) {
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
        
        if status == noErr {
            actions[id] = action
        } else {
            NSLog("[HotKeyManager] Failed to register hotkey id \(id): error code \(status)")
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
