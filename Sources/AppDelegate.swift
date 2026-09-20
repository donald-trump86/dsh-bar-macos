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
        
        ServiceManager.shared.onStatusChanged = { [weak self] running in
            self?.updateUI(running: running)
        }
        
        ServiceManager.shared.startMonitoring()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        
        // Load menu bar icon
        if let iconImage = loadMenuBarIcon() {
            button.image = iconImage
            button.imagePosition = .imageLeft
        } else {
            button.title = "DSH"
        }
    }
    
    private func loadMenuBarIcon() -> NSImage? {
        // First try MenuBarIcon.png
        if let path = Bundle.main.path(forResource: "MenuBarIcon", ofType: "png"),
           let image = NSImage(contentsOfFile: path) {
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        // Fallback to icon.png resized
        if let path = Bundle.main.path(forResource: "icon", ofType: "png"),
           let image = NSImage(contentsOfFile: path) {
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return nil
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
        
        // 6. Dashboard (⌘D)
        dashboardMenuItem = NSMenuItem(
            title: "Show Dashboard Panel...",
            action: #selector(didSelectDashboard),
            keyEquivalent: "d"
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
            title: "Quit DeepSeek Harness Bar",
            action: #selector(didSelectQuit),
            keyEquivalent: "q"
        )
        quitMenuItem.keyEquivalentModifierMask = [.command]
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)
        
        statusItem.menu = menu
    }
    
    private func setupHotKeys() {
        // HotKey 1: Option + Shift + D (Carbon kVK_ANSI_D = 0x02, cmd/opt/shift masks)
        // Carbon modifier masks: optionKey = 0x0800, shiftKey = 0x0200
        let kVK_ANSI_D: UInt32 = 0x02
        let kVK_ANSI_H: UInt32 = 0x04
        // Carbon modifier masks: optionKey = 0x0800, shiftKey = 0x0200
        let optShiftMask: UInt32 = UInt32(0x0800 | 0x0200)
        
        // ⌥ + ⇧ + D: Global shortcut to open DSH Web
        HotKeyManager.shared.register(id: 1, keyCode: kVK_ANSI_D, modifiers: optShiftMask) {
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
        
        // ⌥ + ⇧ + H: Global shortcut to toggle Dashboard panel
        HotKeyManager.shared.register(id: 2, keyCode: kVK_ANSI_H, modifiers: optShiftMask) {
            DashboardWindowController.shared.showWindow(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
    
    private func updateUI(running: Bool) {
        if running {
            statusMenuItem.title = "● DeepSeek Harness: Running (3080)"
            toggleServiceMenuItem.title = "Stop Service"
            toggleServiceMenuItem.isEnabled = true
            openWebMenuItem.isEnabled = true
            restartMenuItem.isEnabled = true
            copyUrlMenuItem.isEnabled = true
            statusItem.button?.toolTip = "DeepSeek Harness: Running on port 3080"
        } else {
            statusMenuItem.title = "○ DeepSeek Harness: Stopped"
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
