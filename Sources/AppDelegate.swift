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
        
        // Listen for port changes
        SettingsManager.shared.onPortChanged = { [weak self] _ in
            self?.updateUI(running: ServiceManager.shared.isRunning)
        }
        
        ServiceManager.shared.onStatusChanged = { [weak self] running in
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
        guard let button = statusItem.button else { return }
        
        // Crisp native whale emoji (no blurry bitmap)
        button.title = "🐳"
        button.image = nil
        button.font = NSFont.systemFont(ofSize: 15)
    }
    
    private func setupMenu() {
        menu = NSMenu()
        menu.autoenablesItems = false
        
        // 1. Status display
        statusMenuItem = NSMenuItem(title: "Checking status...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
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
        if running {
            statusMenuItem.title = "● DeepSeek Harness: Running (\(port))"
            toggleServiceMenuItem.title = "Stop Service"
            toggleServiceMenuItem.isEnabled = true
            openWebMenuItem.isEnabled = true
            restartMenuItem.isEnabled = true
            copyUrlMenuItem.isEnabled = true
            statusItem.button?.toolTip = "DeepSeek Harness: Running on port \(port)"
        } else {
            statusMenuItem.title = "○ DeepSeek Harness: Stopped (\(port))"
            toggleServiceMenuItem.title = "Start Service"
            toggleServiceMenuItem.isEnabled = true
            openWebMenuItem.isEnabled = false
            restartMenuItem.isEnabled = false
            copyUrlMenuItem.isEnabled = false
            statusItem.button?.toolTip = "DeepSeek Harness: Stopped"
        }
        DashboardWindowController.shared.updateState(running)
    }
    
    @objc private func didSelectOpenWeb() {
        ServiceManager.shared.openBrowser()
    }
    
    @objc private func didSelectToggleService() {
        if ServiceManager.shared.isRunning {
            toggleServiceMenuItem.isEnabled = false
            ServiceManager.shared.stopService { [weak self] _ in
                self?.toggleServiceMenuItem.isEnabled = true
            }
        } else {
            toggleServiceMenuItem.isEnabled = false
            ServiceManager.shared.startService { [weak self] success, _ in
                self?.toggleServiceMenuItem.isEnabled = true
                if success {
                    ServiceManager.shared.openBrowser()
                }
            }
        }
    }
    
    @objc private func didSelectRestart() {
        restartMenuItem.isEnabled = false
        ServiceManager.shared.restartService { [weak self] _, _ in
            self?.restartMenuItem.isEnabled = true
        }
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
