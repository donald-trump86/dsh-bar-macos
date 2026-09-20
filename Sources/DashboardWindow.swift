import Cocoa

final class DashboardWindowController: NSWindowController {
    static let shared = DashboardWindowController()
    
    private let statusIndicator = NSTextField(labelWithString: "● Stopped")
    private let urlLabel = NSTextField(labelWithString: "http://127.0.0.1:3080")
    private let toggleButton = NSButton()
    private let openButton = NSButton()
    private let restartButton = NSButton()
    private let logsButton = NSButton()
    
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "DeepSeek Harness"
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
        
        // App Icon
        let iconView = NSImageView(frame: NSRect(x: 24, y: 226, width: 64, height: 64))
        if let icon = NSImage(contentsOfFile: Bundle.main.path(forResource: "icon", ofType: "png") ?? "") {
            iconView.image = icon
        } else {
            iconView.image = NSApplication.shared.applicationIconImage
        }
        visualEffect.addSubview(iconView)
        
        // App Title
        let titleLabel = NSTextField(labelWithString: "DeepSeek Harness")
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.frame = NSRect(x: 100, y: 256, width: 250, height: 26)
        visualEffect.addSubview(titleLabel)
        
        // Status badge
        statusIndicator.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        statusIndicator.frame = NSRect(x: 100, y: 232, width: 250, height: 20)
        visualEffect.addSubview(statusIndicator)
        
        // URL Field Box
        let urlBox = NSBox(frame: NSRect(x: 24, y: 168, width: 332, height: 42))
        urlBox.boxType = .custom
        urlBox.cornerRadius = 8
        urlBox.fillColor = NSColor.textColor.withAlphaComponent(0.06)
        urlBox.borderColor = NSColor.separatorColor.withAlphaComponent(0.3)
        urlBox.borderWidth = 1
        
        urlLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.frame = NSRect(x: 12, y: 10, width: 230, height: 20)
        urlBox.addSubview(urlLabel)
        
        let copyButton = NSButton(title: "Copy", target: self, action: #selector(didClickCopy))
        copyButton.bezelStyle = .inline
        copyButton.frame = NSRect(x: 260, y: 8, width: 60, height: 24)
        urlBox.addSubview(copyButton)
        visualEffect.addSubview(urlBox)
        
        // Action Buttons Row
        openButton.title = "Open Web"
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.target = self
        openButton.action = #selector(didClickOpen)
        openButton.frame = NSRect(x: 22, y: 112, width: 106, height: 32)
        visualEffect.addSubview(openButton)
        
        toggleButton.bezelStyle = .rounded
        toggleButton.target = self
        toggleButton.action = #selector(didClickToggle)
        toggleButton.frame = NSRect(x: 134, y: 112, width: 110, height: 32)
        visualEffect.addSubview(toggleButton)
        
        restartButton.title = "Restart"
        restartButton.bezelStyle = .rounded
        restartButton.target = self
        restartButton.action = #selector(didClickRestart)
        restartButton.frame = NSRect(x: 250, y: 112, width: 108, height: 32)
        visualEffect.addSubview(restartButton)
        
        // Divider
        let divider = NSBox(frame: NSRect(x: 24, y: 96, width: 332, height: 1))
        divider.boxType = .separator
        visualEffect.addSubview(divider)
        
        // Hotkey & tips info
        let hotkeyTip = NSTextField(labelWithString: "Global Hotkey: ⌥ + ⇧ + D  (Launch & Open Web)")
        hotkeyTip.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hotkeyTip.textColor = .secondaryLabelColor
        hotkeyTip.frame = NSRect(x: 24, y: 64, width: 332, height: 18)
        visualEffect.addSubview(hotkeyTip)
        
        // Logs & Close buttons bottom row
        logsButton.title = "View Logs"
        logsButton.bezelStyle = .accessoryBarAction
        logsButton.target = self
        logsButton.action = #selector(didClickLogs)
        logsButton.frame = NSRect(x: 24, y: 22, width: 90, height: 26)
        visualEffect.addSubview(logsButton)
        
        let closeButton = NSButton(title: "Close", target: self, action: #selector(didClickClose))
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.keyEquivalent = "\u{1b}" // ESC
        closeButton.frame = NSRect(x: 286, y: 22, width: 70, height: 26)
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
        self.window?.orderOut(nil)
    }
}
