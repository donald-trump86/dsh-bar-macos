import Foundation
import ServiceManagement
import Carbon
import AppKit

final class SettingsManager {
    static let shared = SettingsManager()
    
    private let keyAutoOpen = "DSH_AutoOpenWebOnLaunch"
    private let keyHotKeyKeyCode = "DSH_GlobalHotKeyKeyCode"
    private let keyHotKeyModifiers = "DSH_GlobalHotKeyModifiers"
    private let keyHotKeyTitle = "DSH_GlobalHotKeyTitle"
    private let keyPort = "DSH_CustomPort"
    
    var onHotKeyChanged: (() -> Void)?
    var onPortChanged: ((Int) -> Void)?
    
    private init() {
        // Defaults
        if UserDefaults.standard.object(forKey: keyAutoOpen) == nil {
            UserDefaults.standard.set(true, forKey: keyAutoOpen)
        }
        if UserDefaults.standard.object(forKey: keyPort) == nil {
            UserDefaults.standard.set(3080, forKey: keyPort)
        }
    }
    
    // MARK: - Port Configuration
    var port: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: keyPort)
            return (val > 0 && val <= 65535) ? val : 3080
        }
        set {
            let clamped = (newValue > 0 && newValue <= 65535) ? newValue : 3080
            UserDefaults.standard.set(clamped, forKey: keyPort)
            onPortChanged?(clamped)
        }
    }
    
    // MARK: - Launch At Login
    var isLaunchAtLoginEnabled: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return UserDefaults.standard.bool(forKey: "DSH_LaunchAtLogin")
        }
        set {
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("[SettingsManager] LaunchAtLogin toggle failed: \(error.localizedDescription)")
                }
            }
            UserDefaults.standard.set(newValue, forKey: "DSH_LaunchAtLogin")
        }
    }
    
    // MARK: - Auto Open Web on Launch
    var autoOpenWebOnLaunch: Bool {
        get {
            return UserDefaults.standard.bool(forKey: keyAutoOpen)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyAutoOpen)
        }
    }
    
    // MARK: - Global HotKey Configuration
    // Default: Option + Shift + D (keyCode 2)
    var globalHotKeyKeyCode: UInt32 {
        get {
            let val = UserDefaults.standard.integer(forKey: keyHotKeyKeyCode)
            return val != 0 ? UInt32(val) : 0x02 // kVK_ANSI_D
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: keyHotKeyKeyCode)
        }
    }
    
    var globalHotKeyModifiers: UInt32 {
        get {
            let val = UserDefaults.standard.integer(forKey: keyHotKeyModifiers)
            return val != 0 ? UInt32(val) : UInt32(0x0800 | 0x0200) // optionKey | shiftKey
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: keyHotKeyModifiers)
        }
    }
    
    var globalHotKeyDisplayString: String {
        get {
            return UserDefaults.standard.string(forKey: keyHotKeyTitle) ?? "⌥ ⇧ D"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyHotKeyTitle)
        }
    }
    
    func updateGlobalHotKey(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.globalHotKeyKeyCode = keyCode
        self.globalHotKeyModifiers = modifiers
        self.globalHotKeyDisplayString = display
        onHotKeyChanged?()
    }
    
    func resetHotKeyToDefault() {
        updateGlobalHotKey(keyCode: 0x02, modifiers: UInt32(0x0800 | 0x0200), display: "⌥ ⇧ D")
    }
}
