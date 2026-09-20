import Cocoa
import Carbon
import ServiceManagement

final class DashboardWindowController: NSWindowController, NSTextFieldDelegate {
    static let shared = DashboardWindowController()
    
    // Status Badge UI
    private let statusBadge = NSBox()
    private let statusDot = NSBox()
    private let statusText = NSTextField(labelWithString: "STOPPED")
    
    // URL Bar UI
    private let urlLabel = NSTextField(labelWithString: "http://127.0.0.1:3080")
    private let copyButton = NSButton()
    
    // Action Buttons
    private let openButton = NSButton()
    private let toggleButton = NSButton()
    private let restartButton = NSButton()
    private let logsButton = NSButton()
    
    // Preferences UI
    private let portField = NSTextField()
    private let portResetButton = NSButton()
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login (开机自动在后台启动)", target: nil, action: nil)
    private let autoOpenCheckbox = NSButton(checkboxWithTitle: "Auto open Web on launch (启动时自动拉起网页)", target: nil, action: nil)
    private let hotKeyButton = NSButton()
    private let hotKeyResetButton = NSButton()
    
    private var localEventMonitor: Any?
    private var isRecordingHotKey = false
    private var copyFeedbackTimer: Timer?
    private var statusObserverToken: UUID?
    private var portObserverToken: UUID?
    
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 580),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Preferences"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.backgroundColor = .clear
        
        super.init(window: window)
        setupUI()
        
        // Subscribe independently: the panel and the menu bar each receive every
        // status/port change. Previously these were single callback slots, so the
        // panel overwrote the menu bar's closure and the menu went stale.
        statusObserverToken = ServiceManager.shared.addStatusObserver { [weak self] running in
            self?.updateState(running)
        }
        portObserverToken = SettingsManager.shared.addPortObserver { [weak self] port in
            self?.updateUrlDisplay(port: port)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func showWindow(_ sender: Any?) {
        // Always reflect the latest state when the panel is brought up.
        updateState(ServiceManager.shared.isRunning)
        super.showWindow(sender)
    }
    
    private func setupUI() {
        guard let window = self.window else { return }
        
        // 1. Frosted Glass Vibrancy Background
        let visualEffect = NSVisualEffectView(frame: window.contentView!.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        window.contentView = visualEffect
        
        // ==========================================
        // 2. HERO HEADER SECTION
        // ==========================================
        let iconView = NSImageView(frame: NSRect(x: 28, y: 486, width: 68, height: 68))
        if let iconPath = Bundle.main.path(forResource: "icon", ofType: "png"),
           let icon = NSImage(contentsOfFile: iconPath) {
            iconView.image = icon
        } else {
            iconView.image = NSApplication.shared.applicationIconImage
        }
        visualEffect.addSubview(iconView)
        
        // Title & Version
        let titleLabel = NSTextField(labelWithString: "DeepSeek Harness")
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        titleLabel.frame = NSRect(x: 110, y: 524, width: 230, height: 26)
        visualEffect.addSubview(titleLabel)
        
        let subTitleLabel = NSTextField(labelWithString: "Menu Bar Companion • v1.0.0")
        subTitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        subTitleLabel.textColor = .secondaryLabelColor
        subTitleLabel.frame = NSRect(x: 110, y: 504, width: 230, height: 18)
        visualEffect.addSubview(subTitleLabel)
        
        // Status Badge Capsule (Top Right)
        statusBadge.frame = NSRect(x: 310, y: 508, width: 142, height: 28)
        statusBadge.boxType = .custom
        statusBadge.cornerRadius = 14
        statusBadge.borderWidth = 1
        
        // Inner Dot inside status badge
        statusDot.frame = NSRect(x: 10, y: 9, width: 10, height: 10)
        statusDot.boxType = .custom
        statusDot.cornerRadius = 5
        statusDot.borderWidth = 0
        statusBadge.addSubview(statusDot)
        
        statusText.frame = NSRect(x: 26, y: 5, width: 110, height: 18)
        statusText.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        statusBadge.addSubview(statusText)
        visualEffect.addSubview(statusBadge)
        
        // ==========================================
        // 3. CARD 1: SERVICE CONTROL PANEL
        // ==========================================
        let card1 = createCardBox(frame: NSRect(x: 24, y: 340, width: 432, height: 132))
        visualEffect.addSubview(card1)
        
        let card1Title = NSTextField(labelWithString: "LOCAL WEB CONSOLE")
        card1Title.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        card1Title.textColor = .tertiaryLabelColor
        card1Title.frame = NSRect(x: 16, y: 104, width: 300, height: 16)
        card1.addSubview(card1Title)
        
        // URL Inner Container Bar
        let urlContainer = NSBox(frame: NSRect(x: 14, y: 58, width: 404, height: 38))
        urlContainer.boxType = .custom
        urlContainer.cornerRadius = 8
        urlContainer.fillColor = NSColor.textColor.withAlphaComponent(0.06)
        urlContainer.borderColor = NSColor.separatorColor.withAlphaComponent(0.2)
        urlContainer.borderWidth = 1
        
        urlLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        urlLabel.textColor = .labelColor
        urlLabel.frame = NSRect(x: 14, y: 10, width: 280, height: 18)
        urlContainer.addSubview(urlLabel)
        
        copyButton.title = "Copy"
        copyButton.bezelStyle = .inline
        copyButton.target = self
        copyButton.action = #selector(didClickCopy)
        copyButton.frame = NSRect(x: 324, y: 7, width: 70, height: 24)
        urlContainer.addSubview(copyButton)
        card1.addSubview(urlContainer)
        
        // Action Buttons Row (3 buttons)
        openButton.title = "Open Web"
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.target = self
        openButton.action = #selector(didClickOpen)
        openButton.frame = NSRect(x: 10, y: 10, width: 136, height: 36)
        card1.addSubview(openButton)
        
        toggleButton.bezelStyle = .rounded
        toggleButton.target = self
        toggleButton.action = #selector(didClickToggle)
        toggleButton.frame = NSRect(x: 148, y: 10, width: 140, height: 36)
        card1.addSubview(toggleButton)
        
        restartButton.title = "Restart"
        restartButton.bezelStyle = .rounded
        restartButton.target = self
        restartButton.action = #selector(didClickRestart)
        restartButton.frame = NSRect(x: 290, y: 10, width: 132, height: 36)
        card1.addSubview(restartButton)
        
        // ==========================================
        // 4. CARD 2: PREFERENCES & SHORTCUTS
        // ==========================================
        let card2 = createCardBox(frame: NSRect(x: 24, y: 74, width: 432, height: 252))
        visualEffect.addSubview(card2)
        
        let card2Title = NSTextField(labelWithString: "PREFERENCES & CONFIGURATION")
        card2Title.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        card2Title.textColor = .tertiaryLabelColor
        card2Title.frame = NSRect(x: 16, y: 224, width: 300, height: 16)
        card2.addSubview(card2Title)
        
        // --- Row 1: Port Setting ---
        let portTitle = NSTextField(labelWithString: "Server Port")
        portTitle.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        portTitle.frame = NSRect(x: 16, y: 190, width: 100, height: 18)
        card2.addSubview(portTitle)
        
        let portDesc = NSTextField(labelWithString: "Standard: 3080")
        portDesc.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        portDesc.textColor = .secondaryLabelColor
        portDesc.frame = NSRect(x: 16, y: 172, width: 140, height: 16)
        card2.addSubview(portDesc)
        
        portField.stringValue = "\(SettingsManager.shared.port)"
        portField.frame = NSRect(x: 270, y: 178, width: 72, height: 26)
        portField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        portField.alignment = .center
        portField.delegate = self
        card2.addSubview(portField)
        
        portResetButton.title = "Default"
        portResetButton.bezelStyle = .inline
        portResetButton.target = self
        portResetButton.action = #selector(didResetPort)
        portResetButton.frame = NSRect(x: 350, y: 180, width: 66, height: 24)
        card2.addSubview(portResetButton)
        
        let sep1 = createCardSeparator(y: 160, width: 400)
        card2.addSubview(sep1)
        
        // --- Row 2: Global Hotkey ---
        let hotKeyTitle = NSTextField(labelWithString: "Global Shortcut")
        hotKeyTitle.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        hotKeyTitle.frame = NSRect(x: 16, y: 126, width: 120, height: 18)
        card2.addSubview(hotKeyTitle)
        
        let hotKeyDesc = NSTextField(labelWithString: "Press anywhere to launch Web")
        hotKeyDesc.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hotKeyDesc.textColor = .secondaryLabelColor
        hotKeyDesc.frame = NSRect(x: 16, y: 108, width: 180, height: 16)
        card2.addSubview(hotKeyDesc)
        
        hotKeyButton.bezelStyle = .rounded
        hotKeyButton.title = SettingsManager.shared.globalHotKeyDisplayString
        hotKeyButton.target = self
        hotKeyButton.action = #selector(didClickRecordHotKey)
        hotKeyButton.frame = NSRect(x: 236, y: 112, width: 116, height: 32)
        card2.addSubview(hotKeyButton)
        
        hotKeyResetButton.title = "Reset"
        hotKeyResetButton.bezelStyle = .inline
        hotKeyResetButton.target = self
        hotKeyResetButton.action = #selector(didClickResetHotKey)
        hotKeyResetButton.frame = NSRect(x: 356, y: 116, width: 60, height: 24)
        card2.addSubview(hotKeyResetButton)
        
        let sep2 = createCardSeparator(y: 98, width: 400)
        card2.addSubview(sep2)
        
        // --- Row 3: Checkboxes ---
        launchAtLoginCheckbox.frame = NSRect(x: 16, y: 62, width: 390, height: 20)
        launchAtLoginCheckbox.state = SettingsManager.shared.isLaunchAtLoginEnabled ? .on : .off
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(didToggleLaunchAtLogin)
        card2.addSubview(launchAtLoginCheckbox)
        
        autoOpenCheckbox.frame = NSRect(x: 16, y: 28, width: 390, height: 20)
        autoOpenCheckbox.state = SettingsManager.shared.autoOpenWebOnLaunch ? .on : .off
        autoOpenCheckbox.target = self
        autoOpenCheckbox.action = #selector(didToggleAutoOpen)
        card2.addSubview(autoOpenCheckbox)
        
        // ==========================================
        // 5. BOTTOM FOOTER BAR
        // ==========================================
        logsButton.title = "View Live Logs"
        logsButton.bezelStyle = .accessoryBarAction
        logsButton.target = self
        logsButton.action = #selector(didClickLogs)
        logsButton.frame = NSRect(x: 24, y: 22, width: 116, height: 30)
        visualEffect.addSubview(logsButton)
        
        let tipLabel = NSTextField(labelWithString: "Preferences: ⌘,  •  Close: Esc")
        tipLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        tipLabel.textColor = .tertiaryLabelColor
        tipLabel.alignment = .right
        tipLabel.frame = NSRect(x: 160, y: 28, width: 210, height: 18)
        visualEffect.addSubview(tipLabel)
        
        let closeButton = NSButton(title: "Done", target: self, action: #selector(didClickClose))
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.keyEquivalent = "\u{1b}" // ESC
        closeButton.frame = NSRect(x: 382, y: 22, width: 74, height: 30)
        visualEffect.addSubview(closeButton)
        
        updateUrlDisplay(port: SettingsManager.shared.port)
    }
    
    private func createCardBox(frame: NSRect) -> NSBox {
        let box = NSBox(frame: frame)
        box.boxType = .custom
        box.cornerRadius = 12
        box.fillColor = NSColor.textColor.withAlphaComponent(0.04)
        box.borderColor = NSColor.separatorColor.withAlphaComponent(0.2)
        box.borderWidth = 1
        return box
    }
    
    private func createCardSeparator(y: CGFloat, width: CGFloat) -> NSBox {
        let sep = NSBox(frame: NSRect(x: 16, y: y, width: width, height: 1))
        sep.boxType = .separator
        return sep
    }
    
    private func updateUrlDisplay(port: Int) {
        urlLabel.stringValue = "http://127.0.0.1:\(port)"
        portField.stringValue = "\(port)"
    }
    
    func updateState(_ isRunning: Bool) {
        let port = ServiceManager.shared.port
        if isRunning {
            statusBadge.fillColor = NSColor.systemGreen.withAlphaComponent(0.15)
            statusBadge.borderColor = NSColor.systemGreen.withAlphaComponent(0.4)
            statusDot.fillColor = NSColor.systemGreen
            statusText.stringValue = "RUNNING : \(port)"
            statusText.textColor = NSColor.systemGreen
            
            toggleButton.title = "Stop Service"
            openButton.isEnabled = true
            restartButton.isEnabled = true
        } else {
            statusBadge.fillColor = NSColor.textColor.withAlphaComponent(0.08)
            statusBadge.borderColor = NSColor.separatorColor.withAlphaComponent(0.3)
            statusDot.fillColor = NSColor.tertiaryLabelColor
            statusText.stringValue = "STOPPED"
            statusText.textColor = NSColor.secondaryLabelColor
            
            toggleButton.title = "Start Service"
            openButton.isEnabled = false
            restartButton.isEnabled = false
        }
        updateUrlDisplay(port: port)
    }
    
    // MARK: - Actions
    @objc private func didClickOpen() {
        ServiceManager.shared.openBrowser()
    }
    
    @objc private func didClickToggle() {
        if ServiceManager.shared.isRunning {
            toggleButton.isEnabled = false
            ServiceManager.shared.stopService { [weak self] success, message in
                self?.toggleButton.isEnabled = true
                if !success, let message = message {
                    self?.showAlert(title: "Could Not Stop the Service", message: message)
                }
            }
        } else {
            toggleButton.isEnabled = false
            ServiceManager.shared.startService { [weak self] success, message in
                self?.toggleButton.isEnabled = true
                if success {
                    ServiceManager.shared.openBrowser()
                } else if let message = message {
                    self?.showAlert(title: "Could Not Start the Service", message: message)
                }
            }
        }
    }
    
    @objc private func didClickRestart() {
        restartButton.isEnabled = false
        ServiceManager.shared.restartService { [weak self] success, message in
            self?.restartButton.isEnabled = true
            if !success, let message = message {
                self?.showAlert(title: "Could Not Restart the Service", message: message)
            }
        }
    }
    
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    
    @objc private func didClickLogs() {
        ServiceManager.shared.openLogs()
    }
    
    @objc private func didClickCopy() {
        ServiceManager.shared.copyURLToClipboard()
        copyButton.title = "Copied!"
        copyButton.isEnabled = false
        copyFeedbackTimer?.invalidate()
        copyFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.copyButton.title = "Copy"
            self?.copyButton.isEnabled = true
        }
    }
    
    // MARK: - Port Actions
    private func applyCurrentPort() {
        let text = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let newPort = Int(text), newPort > 0, newPort <= 65535 {
            if newPort != SettingsManager.shared.port {
                SettingsManager.shared.port = newPort
                updateUrlDisplay(port: newPort)
                
                if ServiceManager.shared.isRunning {
                    let alert = NSAlert()
                    alert.messageText = "Port Updated to \(newPort)"
                    alert.informativeText = "The server is currently running. Would you like to restart the service on the new port now?"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "Restart Now")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn {
                        didClickRestart()
                    }
                }
            }
        } else {
            portField.stringValue = "\(SettingsManager.shared.port)"
        }
    }
    
    @objc private func didResetPort() {
        portField.stringValue = "3080"
        applyCurrentPort()
    }
    
    func controlTextDidEndEditing(_ obj: Notification) {
        applyCurrentPort()
    }
    
    // MARK: - HotKey Recording
    @objc private func didClickRecordHotKey() {
        if isRecordingHotKey {
            stopRecording(cancelled: true)
            return
        }
        
        isRecordingHotKey = true
        hotKeyButton.title = "Recording..."
        hotKeyButton.highlight(true)
        
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self, self.isRecordingHotKey else { return event }
            
            // ESC cancels recording
            if event.keyCode == 53 {
                self.stopRecording(cancelled: true)
                return nil
            }
            
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) || flags.contains(.shift) else {
                return nil
            }
            
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
    
    @objc private func didClickClose() {
        if isRecordingHotKey {
            stopRecording(cancelled: true)
        }
        self.window?.orderOut(nil)
    }
}
