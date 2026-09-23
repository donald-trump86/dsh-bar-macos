import Foundation
import ServiceManagement
import Carbon
import AppKit

final class SettingsManager {
    static let shared = SettingsManager()
    
    private let keyHotKeyKeyCode = "DSH_GlobalHotKeyKeyCode"
    private let keyHotKeyModifiers = "DSH_GlobalHotKeyModifiers"
    private let keyHotKeyTitle = "DSH_GlobalHotKeyTitle"
    private let keyPort = "DSH_CustomPort"
    
    var onHotKeyChanged: (() -> Void)?

    // Port changes are broadcast to every interested component (menu bar and
    // preferences panel). A single callback slot allowed one component to
    // silently overwrite another one's closure.
    private var portObservers: [UUID: (Int) -> Void] = [:]

    @discardableResult
    func addPortObserver(_ observer: @escaping (Int) -> Void) -> UUID {
        let token = UUID()
        portObservers[token] = observer
        observer(port) // deliver the current value immediately
        return token
    }

    func removePortObserver(_ token: UUID) {
        portObservers.removeValue(forKey: token)
    }

    private func notifyPortObservers(_ newPort: Int) {
        for observer in Array(portObservers.values) {
            observer(newPort)
        }
    }
    
    private init() {
        // Defaults
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
            notifyPortObservers(clamped)
        }
    }
    
    // MARK: - Language
    /// Stored as the raw case name so an unknown value falls back to automatic.
    var language: AppLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "DSH_Language"),
                  let value = AppLanguage(rawValue: raw) else {
                return .automatic
            }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "DSH_Language")
            Localization.shared.apply(language: newValue)
        }
    }

    // MARK: - Service Recovery
    /// Whether DSH Bar should bring back a service it started after an
    /// unexpected exit. Defaults to on: silently losing the console is worse
    /// than a bounded restart. External services are never affected by this.
    var autoRestartEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: "DSH_AutoRestart") != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: "DSH_AutoRestart")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "DSH_AutoRestart")
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
    
    // MARK: - Global HotKey Configuration
    // Default: Option + Shift + D (keyCode 0x02 / kVK_ANSI_D)
    private static let defaultHotKeyKeyCode: UInt32 = 0x02
    private static let defaultHotKeyModifiers: UInt32 = 0x0800 | 0x0200 // optionKey | shiftKey
    private static let defaultHotKeyDisplay = "⌥ ⇧ D"
    
    /// `integer(forKey:)` cannot tell "unset" from a stored 0, and 0 is a real key
    /// code (kVK_ANSI_A) — recording ⌘A/⌥A used to silently fall back to the default.
    var globalHotKeyKeyCode: UInt32 {
        get {
            guard UserDefaults.standard.object(forKey: keyHotKeyKeyCode) != nil else {
                return Self.defaultHotKeyKeyCode
            }
            return UInt32(UserDefaults.standard.integer(forKey: keyHotKeyKeyCode))
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: keyHotKeyKeyCode)
        }
    }
    
    var globalHotKeyModifiers: UInt32 {
        get {
            guard UserDefaults.standard.object(forKey: keyHotKeyModifiers) != nil else {
                return Self.defaultHotKeyModifiers
            }
            return UInt32(UserDefaults.standard.integer(forKey: keyHotKeyModifiers))
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: keyHotKeyModifiers)
        }
    }
    
    var globalHotKeyDisplayString: String {
        get {
            return UserDefaults.standard.string(forKey: keyHotKeyTitle) ?? Self.defaultHotKeyDisplay
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
        updateGlobalHotKey(
            keyCode: Self.defaultHotKeyKeyCode,
            modifiers: Self.defaultHotKeyModifiers,
            display: Self.defaultHotKeyDisplay
        )
    }
}
