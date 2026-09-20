import Cocoa
import Carbon
import ServiceManagement

final class DashboardWindowController: NSWindowController {
    static let shared = DashboardWindowController()
    
    private let statusIndicator = NSTextField(labelWithString: "● Stopped")
    private let urlLabel = NSTextField(labelWithString: "http://127.0.0.1:3080")
    private let toggleButton = NSButton()
    private let openButton = NSButton()
    private let restartButton = NSButton()
    private let logsButton = NSButton()
    
    // Preferences UI
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login (开机自动启动)", target: nil, action: nil)
    private let autoOpenCheckbox = NSButton(checkboxWithTitle: "Auto open Web UI on launch (启动时自动打开网页)", target: nil, action: nil)
    private let hotKeyButton = NSButton()
    private var localEventMonitor: Any?
    private var isRecordingHotKey = false
    
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "DeepSeek Harness Preferences"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.backgroundColor = .clear
        
        super.init(window: window)
        setupUI()
        updateState(ServiceManager.shared.isRunning)
        
        ServiceManager.shared.onStatusChanged = { [weak self] running in
            self?.updateState(running)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        guard let window = self.window else { return }
        
        // Visual effect background (vibrancy / blur)
        let visualEffect = NSVisualEffectView(frame: window.contentView!.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        window.contentView = visualEffect
        
        // 1. App Icon (64x64)
        let iconView = NSImageView(frame: NSRect(x: 24, y: 390, width: 64, height: 64))
        if let iconPath = Bundle.main.path(forResource: "icon", ofType: "png"),
           let icon = NSImage(contentsOfFile: iconPath) {
            iconView.image = icon
        } else {
            iconView.image = NSApplication.shared.applicationIconImage
        }
        visualEffect.addSubview(iconView)
        
        // 2. App Title & Status
        let titleLabel = NSTextField(labelWithString: "DeepSeek Harness")
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.frame = NSRect(x: 102, y: 422, width: 280, height: 26)
        visualEffect.addSubview(titleLabel)
        
        statusIndicator.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        statusIndicator.frame = NSRect(x: 102, y: 398, width: 280, height: 20)
        visualEffect.addSubview(statusIndicator)
        
        // 3. URL Box
        let urlBox = NSBox(frame: NSRect(x: 24, y: 334, width: 372, height: 44))
        urlBox.boxType = .custom
        urlBox.cornerRadius = 8
        urlBox.fillColor = NSColor.textColor.withAlphaComponent(0.06)
        urlBox.borderColor = NSColor.separatorColor.withAlphaComponent(0.25)
        urlBox.borderWidth = 1
        
        urlLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.frame = NSRect(x: 12, y: 12, width: 260, height: 20)
        urlBox.addSubview(urlLabel)
        
        let copyButton = NSButton(title: "Copy", target: self, action: #selector(didClickCopy))
        copyButton.bezelStyle = .inline
        copyButton.frame = NSRect(x: 292, y: 9, width: 68, height: 26)
        urlBox.addSubview(copyButton)
        visualEffect.addSubview(urlBox)
        
        // 4. Action Buttons Row
        openButton.title = "Open Web"
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.target = self
        openButton.action = #selector(didClickOpen)
        openButton.frame = NSRect(x: 22, y: 286, width: 116, height: 32)
        visualEffect.addSubview(openButton)
        
        toggleButton.bezelStyle = .rounded
        toggleButton.target = self
        toggleButton.action = #selector(didClickToggle)
        toggleButton.frame = NSRect(x: 146, y: 286, width: 126, height: 32)
        visualEffect.addSubview(toggleButton)
        
        restartButton.title = "Restart"
        restartButton.bezelStyle = .rounded
        restartButton.target = self
        restartButton.action = #selector(didClickRestart)
        restartButton.frame = NSRect(x: 280, y: 286, width: 118, height: 32)
        visualEffect.addSubview(restartButton)
        
        // Divider 1
        let divider1 = NSBox(frame: NSRect(x: 24, y: 270, width: 372, height: 1))
        divider1.boxType = .separator
        visualEffect.addSubview(divider1)
        
        // 5. Preferences & Settings Section
        let prefHeader = NSTextField(labelWithString: "PREFERENCES & SHORTCUTS")
        prefHeader.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        prefHeader.textColor = .secondaryLabelColor
        prefHeader.frame = NSRect(x: 24, y: 244, width: 372, height: 16)
        visualEffect.addSubview(prefHeader)
        
        // HotKey Setting Row
        let hotKeyLabel = NSTextField(labelWithString: "Global Web Hotkey:")
        hotKeyLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        hotKeyLabel.frame = NSRect(x: 24, y: 212, width: 140, height: 22)
        visualEffect.addSubview(hotKeyLabel)
        
        hotKeyButton.bezelStyle = .rounded
        hotKeyButton.title = SettingsManager.shared.globalHotKeyDisplayString
        hotKeyButton.target = self
        hotKeyButton.action = #selector(didClickRecordHotKey)
        hotKeyButton.frame = NSRect(x: 170, y: 206, width: 130, height: 32)
        visualEffect.addSubview(hotKeyButton)
        
        let resetHotKeyButton = NSButton(title: "Reset", target: self, action: #selector(didClickResetHotKey))
        resetHotKeyButton.bezelStyle = .inline
        resetHotKeyButton.frame = NSRect(x: 310, y: 210, width: 60, height: 24)
        visualEffect.addSubview(resetHotKeyButton)
        
        let hotKeyHint = NSTextField(labelWithString: "Click button then press your custom shortcut (e.g. ⌃⌥D)")
        hotKeyHint.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        hotKeyHint.textColor = .tertiaryLabelColor
        hotKeyHint.frame = NSRect(x: 24, y: 188, width: 372, height: 14)
        visualEffect.addSubview(hotKeyHint)
        
        // Launch at login checkbox
        launchAtLoginCheckbox.frame = NSRect(x: 24, y: 154, width: 372, height: 22)
        launchAtLoginCheckbox.state = SettingsManager.shared.isLaunchAtLoginEnabled ? .on : .off
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(didToggleLaunchAtLogin)
        visualEffect.addSubview(launchAtLoginCheckbox)
        
        // Auto open web checkbox
        autoOpenCheckbox.frame = NSRect(x: 24, y: 124, width: 372, height: 22)
        autoOpenCheckbox.state = SettingsManager.shared.autoOpenWebOnLaunch ? .on : .off
        autoOpenCheckbox.target = self
        autoOpenCheckbox.action = #selector(didToggleAutoOpen)
        visualEffect.addSubview(autoOpenCheckbox)
        
        // HotKey tips
        let tipsLabel = NSTextField(labelWithString: "Other Shortcuts: ⌘O (Open)  ⌘S (Stop/Start)  ⌘R (Restart)  ⌘L (Logs)")
        tipsLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        tipsLabel.textColor = .secondaryLabelColor
        tipsLabel.frame = NSRect(x: 24, y: 86, width: 372, height: 18)
        visualEffect.addSubview(tipsLabel)
        
        // Divider 2
        let divider2 = NSBox(frame: NSRect(x: 24, y: 70, width: 372, height: 1))
        divider2.boxType = .separator
        visualEffect.addSubview(divider2)
        
        // 6. Bottom row: View Logs & Close
        logsButton.title = "View Live Logs"
        logsButton.bezelStyle = .accessoryBarAction
        logsButton.target = self
        logsButton.action = #selector(didClickLogs)
        logsButton.frame = NSRect(x: 24, y: 22, width: 110, height: 28)
        visualEffect.addSubview(logsButton)
        
        let closeButton = NSButton(title: "Done", target: self, action: #selector(didClickClose))
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.keyEquivalent = "\u{1b}" // ESC
        closeButton.frame = NSRect(x: 326, y: 22, width: 70, height: 28)
        visualEffect.addSubview(closeButton)
    }
    
    func updateState(_ isRunning: Bool) {
        if isRunning {
            statusIndicator.stringValue = "● Running (Port 3080)"
            statusIndicator.textColor = NSColor.systemGreen
            toggleButton.title = "Stop Service"
            openButton.isEnabled = true
            restartButton.isEnabled = true
        } else {
            statusIndicator.stringValue = "○ Stopped"
            statusIndicator.textColor = NSColor.secondaryLabelColor
            toggleButton.title = "Start Service"
            openButton.isEnabled = false
            restartButton.isEnabled = false
        }
    }
    
    // MARK: - HotKey Recording
    @objc private func didClickRecordHotKey() {
        if isRecordingHotKey {
            stopRecording(cancelled: true)
            return
        }
        
        isRecordingHotKey = true
        hotKeyButton.title = "Press Keys..."
        hotKeyButton.highlight(true)
        
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self, self.isRecordingHotKey else { return event }
            
            // ESC cancels recording
            if event.keyCode == 53 {
                self.stopRecording(cancelled: true)
                return nil
            }
            
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Require at least one modifier key
            guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) || flags.contains(.shift) else {
                return nil
            }
            
            // Convert to Carbon modifiers
            var carbonModifiers: UInt32 = 0
            var symbols = ""
            if flags.contains(.control) {
                carbonModifiers |= UInt32(controlKey)
                symbols += "⌃ "
            }
            if flags.contains(.option) {
                carbonModifiers |= UInt32(0x0800) // optionKey
                symbols += "⌥ "
            }
            if flags.contains(.shift) {
                carbonModifiers |= UInt32(0x0200) // shiftKey
                symbols += "⇧ "
            }
            if flags.contains(.command) {
                carbonModifiers |= UInt32(cmdKey)
                symbols += "⌘ "
            }
            
            let keyString = event.charactersIgnoringModifiers?.uppercased() ?? "Key"
            let display = "\(symbols)\(keyString)"
            
            SettingsManager.shared.updateGlobalHotKey(
                keyCode: UInt32(event.keyCode),
                modifiers: carbonModifiers,
                display: display
            )
            
            self.stopRecording(cancelled: false)
            return nil
        }
    }
    
    private func stopRecording(cancelled: Bool) {
        isRecordingHotKey = false
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        hotKeyButton.highlight(false)
        hotKeyButton.title = SettingsManager.shared.globalHotKeyDisplayString
    }
    
    @objc private func didClickResetHotKey() {
        if isRecordingHotKey {
            stopRecording(cancelled: true)
        }
        SettingsManager.shared.resetHotKeyToDefault()
        hotKeyButton.title = SettingsManager.shared.globalHotKeyDisplayString
    }
    
    // MARK: - Preferences Actions
    @objc private func didToggleLaunchAtLogin() {
        let enabled = (launchAtLoginCheckbox.state == .on)
        SettingsManager.shared.isLaunchAtLoginEnabled = enabled
    }
    
    @objc private func didToggleAutoOpen() {
        let enabled = (autoOpenCheckbox.state == .on)
        SettingsManager.shared.autoOpenWebOnLaunch = enabled
    }
    
    // MARK: - Service Actions
    @objc private func didClickOpen() {
        ServiceManager.shared.openBrowser()
    }
    
    @objc private func didClickToggle() {
        if ServiceManager.shared.isRunning {
            toggleButton.isEnabled = false
            ServiceManager.shared.stopService { [weak self] _ in
                self?.toggleButton.isEnabled = true
            }
        } else {
            toggleButton.isEnabled = false
            ServiceManager.shared.startService { [weak self] success, _ in
                self?.toggleButton.isEnabled = true
                if success {
                    ServiceManager.shared.openBrowser()
                }
            }
        }
    }
    
    @objc private func didClickRestart() {
        restartButton.isEnabled = false
        ServiceManager.shared.restartService { [weak self] _, _ in
            self?.restartButton.isEnabled = true
        }
    }
    
    @objc private func didClickLogs() {
        ServiceManager.shared.openLogs()
    }
    
    @objc private func didClickCopy() {
        ServiceManager.shared.copyURLToClipboard()
    }
    
    @objc private func didClickClose() {
        if isRecordingHotKey {
            stopRecording(cancelled: true)
        }
        self.window?.orderOut(nil)
    }
}
