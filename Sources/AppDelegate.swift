import Cocoa
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    
    // Menu items
    private var statusMenuItem: NSMenuItem!
    private var openWebMenuItem: NSMenuItem!
    private var toggleServiceMenuItem: NSMenuItem!
    private var restartMenuItem: NSMenuItem!
    private var copyUrlMenuItem: NSMenuItem!
    private var logsMenuItem: NSMenuItem!
    private var dashboardMenuItem: NSMenuItem!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory) // Menu bar only (no dock clutter)
        
        setupStatusItem()
        setupMenu()
        setupHotKeys()
        
        // Listen for hotkey configuration changes
        SettingsManager.shared.onHotKeyChanged = { [weak self] in
            self?.setupHotKeys()
        }
        
        // Observe port changes: keep the menu bar's port display in sync.
        SettingsManager.shared.addPortObserver { [weak self] _ in
            self?.updateUI(running: ServiceManager.shared.isRunning)
        }
        
        // Observe service status: refresh the menu bar light, status line and items.
        ServiceManager.shared.addStatusObserver { [weak self] running in
            self?.updateUI(running: running)
        }
        
        ServiceManager.shared.startMonitoring()
        
        // Auto open web on launch if enabled
        if SettingsManager.shared.autoOpenWebOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if ServiceManager.shared.isRunning {
                    ServiceManager.shared.openBrowser()
                } else {
                    ServiceManager.shared.startService { success, _ in
                        if success {
                            ServiceManager.shared.openBrowser()
                        }
                    }
                }
            }
        }
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIndicator(running: ServiceManager.shared.isRunning)
    }
    
    /// Menu bar light: the whale emoji plus a colored status dot
    /// (green = online, gray = stopped).
    private func updateMenuBarIndicator(running: Bool) {
        guard let button = statusItem.button else { return }
        
        let title = NSMutableAttributedString(
            string: "🐳 ",
            attributes: [.font: NSFont.systemFont(ofSize: 15)]
        )
        title.append(NSAttributedString(
            string: "●",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: running ? NSColor.systemGreen : NSColor.systemGray
            ]
        ))
        button.image = nil
        button.attributedTitle = title
    }
    
    /// The status line carries a colored dot; the item has no action but stays
    /// enabled so AppKit does not dim the custom colors.
    private func updateStatusMenuItem(running: Bool, port: Int) {
        let title = NSMutableAttributedString(
            string: running ? "● " : "○ ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: running ? NSColor.systemGreen : NSColor.secondaryLabelColor
            ]
        )
        title.append(NSAttributedString(
            string: running ? "DeepSeek Harness: Running (\(port))" : "DeepSeek Harness: Stopped (\(port))",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor
            ]
        ))
        statusMenuItem.attributedTitle = title
    }
    
    private func setupMenu() {
        menu = NSMenu()
        menu.autoenablesItems = false
        
        // 1. Status display (kept enabled but inert so the colored dot is not dimmed)
        statusMenuItem = NSMenuItem(title: "Checking status...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = true
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 2. Open Web (⌘O)
        openWebMenuItem = NSMenuItem(
            title: "Open Web Console",
            action: #selector(didSelectOpenWeb),
            keyEquivalent: "o"
        )
        openWebMenuItem.keyEquivalentModifierMask = [.command]
        openWebMenuItem.target = self
        menu.addItem(openWebMenuItem)
        
        // 3. Start / Stop Service (⌘S)
        toggleServiceMenuItem = NSMenuItem(
            title: "Start Service",
            action: #selector(didSelectToggleService),
            keyEquivalent: "s"
        )
        toggleServiceMenuItem.keyEquivalentModifierMask = [.command]
        toggleServiceMenuItem.target = self
        menu.addItem(toggleServiceMenuItem)
        
        // 4. Restart (⌘R)
        restartMenuItem = NSMenuItem(
            title: "Restart Service",
            action: #selector(didSelectRestart),
            keyEquivalent: "r"
        )
        restartMenuItem.keyEquivalentModifierMask = [.command]
        restartMenuItem.target = self
        menu.addItem(restartMenuItem)
        
        // 5. Copy URL (⇧⌘C)
        copyUrlMenuItem = NSMenuItem(
            title: "Copy Web URL",
            action: #selector(didSelectCopyUrl),
            keyEquivalent: "c"
        )
        copyUrlMenuItem.keyEquivalentModifierMask = [.command, .shift]
        copyUrlMenuItem.target = self
        menu.addItem(copyUrlMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 6. Preferences (⌘,) - macOS standard shortcut
        dashboardMenuItem = NSMenuItem(
            title: "Preferences...",
            action: #selector(didSelectDashboard),
            keyEquivalent: ","
        )
        dashboardMenuItem.keyEquivalentModifierMask = [.command]
        dashboardMenuItem.target = self
        menu.addItem(dashboardMenuItem)
        
        // 7. View Logs (⌘L)
        logsMenuItem = NSMenuItem(
            title: "View Live Logs...",
            action: #selector(didSelectLogs),
            keyEquivalent: "l"
        )
        logsMenuItem.keyEquivalentModifierMask = [.command]
        logsMenuItem.target = self
        menu.addItem(logsMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 8. Quit (⌘Q)
        let quitMenuItem = NSMenuItem(
            title: "Quit DSH Bar",
            action: #selector(didSelectQuit),
            keyEquivalent: "q"
        )
        quitMenuItem.keyEquivalentModifierMask = [.command]
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)
        
        statusItem.menu = menu
    }
    
    private func setupHotKeys() {
        let settings = SettingsManager.shared
        let keyCode = settings.globalHotKeyKeyCode
        let modifiers = settings.globalHotKeyModifiers
        
        // Primary Global Shortcut to Open Web / Launch
        HotKeyManager.shared.register(id: 1, keyCode: keyCode, modifiers: modifiers) {
            if ServiceManager.shared.isRunning {
                ServiceManager.shared.openBrowser()
            } else {
                ServiceManager.shared.startService { success, _ in
                    if success {
                        ServiceManager.shared.openBrowser()
                    }
                }
            }
        }
        
        // Secondary Global Shortcut: ⌥ + ⇧ + H to toggle Preferences
        let kVK_ANSI_H: UInt32 = 0x04
        let optShiftMask: UInt32 = UInt32(0x0800 | 0x0200)
        HotKeyManager.shared.register(id: 2, keyCode: kVK_ANSI_H, modifiers: optShiftMask) {
            DashboardWindowController.shared.showWindow(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
    
    private func updateUI(running: Bool) {
        let port = ServiceManager.shared.port
        updateMenuBarIndicator(running: running)
        updateStatusMenuItem(running: running, port: port)
        if running {
            toggleServiceMenuItem.title = "Stop Service"
            toggleServiceMenuItem.isEnabled = true
            openWebMenuItem.isEnabled = true
            restartMenuItem.isEnabled = true
            copyUrlMenuItem.isEnabled = true
            statusItem.button?.toolTip = "DeepSeek Harness: Running on port \(port)"
        } else {
            toggleServiceMenuItem.title = "Start Service"
            toggleServiceMenuItem.isEnabled = true
            openWebMenuItem.isEnabled = false
            restartMenuItem.isEnabled = false
            copyUrlMenuItem.isEnabled = false
            statusItem.button?.toolTip = "DeepSeek Harness: Stopped"
        }
    }
    
    @objc private func didSelectOpenWeb() {
        ServiceManager.shared.openBrowser()
    }
    
    @objc private func didSelectToggleService() {
        if ServiceManager.shared.isRunning {
            toggleServiceMenuItem.isEnabled = false
            ServiceManager.shared.stopService { [weak self] success, message in
                self?.toggleServiceMenuItem.isEnabled = true
                if !success, let message = message {
                    self?.showAlert(title: "Could Not Stop the Service", message: message)
                }
            }
        } else {
            toggleServiceMenuItem.isEnabled = false
            ServiceManager.shared.startService { [weak self] success, message in
                self?.toggleServiceMenuItem.isEnabled = true
                if success {
                    ServiceManager.shared.openBrowser()
                } else if let message = message {
                    self?.showAlert(title: "Could Not Start the Service", message: message)
                }
            }
        }
    }
    
    @objc private func didSelectRestart() {
        restartMenuItem.isEnabled = false
        ServiceManager.shared.restartService { [weak self] success, message in
            self?.restartMenuItem.isEnabled = true
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
    
    @objc private func didSelectCopyUrl() {
        ServiceManager.shared.copyURLToClipboard()
    }
    
    @objc private func didSelectDashboard() {
        DashboardWindowController.shared.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    
    @objc private func didSelectLogs() {
        ServiceManager.shared.openLogs()
    }
    
    @objc private func didSelectQuit() {
        NSApplication.shared.terminate(nil)
    }
}
