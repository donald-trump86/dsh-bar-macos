import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    private var statusMenuItem: NSMenuItem!
    private var detailsMenuItem: NSMenuItem!
    private var openWebMenuItem: NSMenuItem!
    private var toggleServiceMenuItem: NSMenuItem!
    private var restartMenuItem: NSMenuItem!
    private var copyUrlMenuItem: NSMenuItem!
    private var logsMenuItem: NSMenuItem!
    private var dashboardMenuItem: NSMenuItem!
    private var quitAndStopMenuItem: NSMenuItem!
    private var notifierObserverToken: UUID?
    /// Set by `Quit & Stop Service…` so `applicationShouldTerminate` knows the
    /// user asked for the service to go away too, and can wait for the stop.
    private var pendingQuitStopsService = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        setupStatusItem()
        setupMenu()
        setupHotKeys()

        SettingsManager.shared.onHotKeyChanged = { [weak self] in
            self?.setupHotKeys()
        }

        SettingsManager.shared.addPortObserver { [weak self] _ in
            self?.updateUI(snapshot: ServiceManager.shared.snapshot)
        }

        ServiceManager.shared.addStatusObserver { [weak self] snapshot in
            self?.updateUI(snapshot: snapshot)
        }

        // Notifications are the channel that reaches the user while they are
        // looking somewhere else. Activate the delegate now; the permission
        // prompt waits until a service is actually started.
        ServiceNotifier.shared.activate()
        notifierObserverToken = ServiceNotifier.shared.addObserver { [weak self] in
            self?.updateUI(snapshot: ServiceManager.shared.snapshot)
        }
        ServiceNotifier.shared.refreshAvailability()

        // Start quietly. The Web console only opens from Open Web or its global
        // shortcut, never from app launch, Start Service, or Restart Service.
        ServiceManager.shared.startMonitoring()
    }

    /// Quit keeps the service running by default (that is what the menu bar
    /// icon disappearing should mean for a background console), so nothing is
    /// stopped here. `Quit & Stop Service…` opts into the other behaviour.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if pendingQuitStopsService {
            pendingQuitStopsService = false
            ServiceManager.shared.stopServiceForQuit { _, _ in
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        ServiceManager.shared.prepareForTermination()
        return .terminateNow
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIndicator(for: ServiceManager.shared.snapshot.phase)
    }

    private func color(for phase: ServicePhase) -> NSColor {
        switch phase {
        case .running:
            return .systemGreen
        case .starting, .stopping, .restarting, .checking:
            return .systemOrange
        case .portConflict, .error:
            return .systemRed
        case .stopped:
            return .systemGray
        }
    }

    /// An unacknowledged unexpected exit is worth showing even when the service
    /// is stopped or already recovered, because it is the fallback channel for
    /// the case where no notification reached the user.
    private var hasRecoveryAlert: Bool {
        ServiceManager.shared.lastUnexpectedExit != nil
    }

    private func updateMenuBarIndicator(for phase: ServicePhase) {
        guard let button = statusItem.button else { return }
        let title = NSMutableAttributedString(
            string: "🐳 ",
            attributes: [.font: NSFont.systemFont(ofSize: 15)]
        )
        let dotColor: NSColor
        if hasRecoveryAlert, phase != .running {
            // Never let a crash look like a normal stop.
            dotColor = .systemRed
        } else {
            dotColor = color(for: phase)
        }
        title.append(NSAttributedString(
            string: "●",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: dotColor
            ]
        ))
        button.image = nil
        button.attributedTitle = title
    }

    private func statusTitle(for snapshot: ServiceSnapshot) -> String {
        switch snapshot.phase {
        case .checking:
            return "Checking DeepSeek Harness…"
        case .stopped:
            return "DeepSeek Harness: Stopped (\(snapshot.port))"
        case .starting:
            return "DeepSeek Harness: Starting…"
        case .running:
            return "DeepSeek Harness: Running (\(snapshot.port))"
        case .stopping:
            return "DeepSeek Harness: Stopping…"
        case .restarting:
            return "DeepSeek Harness: Restarting…"
        case .portConflict:
            return "Port \(snapshot.port) Is in Use"
        case .error:
            return "DeepSeek Harness: Error"
        }
    }

    private func updateStatusItems(snapshot: ServiceSnapshot) {
        let indicator = snapshot.phase == .stopped ? "○ " : "● "
        let title = NSMutableAttributedString(
            string: indicator,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: color(for: snapshot.phase)
            ]
        )
        title.append(NSAttributedString(
            string: statusTitle(for: snapshot),
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor
            ]
        ))
        statusMenuItem.attributedTitle = title

        var details: [String] = []
        if let pid = snapshot.pid { details.append("PID \(pid)") }
        if let uptime = snapshot.uptime { details.append("Up \(Self.formatDuration(uptime))") }
        if let version = snapshot.dshVersion { details.append("DSH \(version)") }
        if details.isEmpty, let message = snapshot.message {
            details.append(message)
        }
        if details.isEmpty {
            if !ServiceManager.shared.dshDetectionComplete {
                details.append("DSH CLI: detecting…")
            } else if snapshot.dshPath == nil {
                details.append("DSH CLI: not installed")
            } else if let path = snapshot.dshPath {
                details.append("DSH: \(path)")
            }
        }
        detailsMenuItem.title = details.joined(separator: "  •  ")
        detailsMenuItem.isHidden = false
    }

    private func setupMenu() {
        menu = NSMenu()
        menu.autoenablesItems = false

        statusMenuItem = NSMenuItem(title: "Checking status…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = true
        menu.addItem(statusMenuItem)

        detailsMenuItem = NSMenuItem(title: "DSH CLI: detecting…", action: nil, keyEquivalent: "")
        detailsMenuItem.isEnabled = false
        menu.addItem(detailsMenuItem)

        menu.addItem(.separator())

        openWebMenuItem = NSMenuItem(
            title: "Open Web Console",
            action: #selector(didSelectOpenWeb),
            keyEquivalent: "o"
        )
        openWebMenuItem.keyEquivalentModifierMask = [.command]
        openWebMenuItem.target = self
        menu.addItem(openWebMenuItem)

        toggleServiceMenuItem = NSMenuItem(
            title: "Start Service",
            action: #selector(didSelectToggleService),
            keyEquivalent: "s"
        )
        toggleServiceMenuItem.keyEquivalentModifierMask = [.command]
        toggleServiceMenuItem.target = self
        menu.addItem(toggleServiceMenuItem)

        restartMenuItem = NSMenuItem(
            title: "Restart Service",
            action: #selector(didSelectRestart),
            keyEquivalent: "r"
        )
        restartMenuItem.keyEquivalentModifierMask = [.command]
        restartMenuItem.target = self
        menu.addItem(restartMenuItem)

        copyUrlMenuItem = NSMenuItem(
            title: "Copy Web URL",
            action: #selector(didSelectCopyUrl),
            keyEquivalent: "c"
        )
        copyUrlMenuItem.keyEquivalentModifierMask = [.command, .shift]
        copyUrlMenuItem.target = self
        menu.addItem(copyUrlMenuItem)

        menu.addItem(.separator())

        dashboardMenuItem = NSMenuItem(
            title: "Preferences…",
            action: #selector(didSelectDashboard),
            keyEquivalent: ","
        )
        dashboardMenuItem.keyEquivalentModifierMask = [.command]
        dashboardMenuItem.target = self
        menu.addItem(dashboardMenuItem)

        logsMenuItem = NSMenuItem(
            title: "View Live Logs…",
            action: #selector(didSelectLogs),
            keyEquivalent: "l"
        )
        logsMenuItem.keyEquivalentModifierMask = [.command]
        logsMenuItem.target = self
        menu.addItem(logsMenuItem)

        menu.addItem(.separator())

        let quitMenuItem = NSMenuItem(
            title: "Quit DSH Bar",
            action: #selector(didSelectQuit),
            keyEquivalent: "q"
        )
        quitMenuItem.keyEquivalentModifierMask = [.command]
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        // The two quits differ in what happens to the service, so the titles say
        // so rather than relying on the user remembering.
        quitAndStopMenuItem = NSMenuItem(
            title: "Quit & Stop Service…",
            action: #selector(didSelectQuitAndStopService),
            keyEquivalent: "q"
        )
        quitAndStopMenuItem.keyEquivalentModifierMask = [.command, .option]
        quitAndStopMenuItem.target = self
        menu.addItem(quitAndStopMenuItem)

        statusItem.menu = menu
    }

    private func setupHotKeys() {
        let settings = SettingsManager.shared
        HotKeyManager.shared.register(
            id: 1,
            keyCode: settings.globalHotKeyKeyCode,
            modifiers: settings.globalHotKeyModifiers
        ) { [weak self] in
            if ServiceManager.shared.isRunning {
                ServiceManager.shared.openBrowser()
            } else {
                ServiceManager.shared.startService { success, message in
                    if success {
                        ServiceManager.shared.openBrowser()
                    } else if let message {
                        self?.handleStartFailure(message)
                    }
                }
            }
        }

        // The former fixed ⌥⇧H shortcut for Preferences is intentionally removed.
        HotKeyManager.shared.unregister(id: 2)
    }

    private func updateUI(snapshot: ServiceSnapshot) {
        updateMenuBarIndicator(for: snapshot.phase)
        updateStatusItems(snapshot: snapshot)

        let busy = snapshot.phase.isBusy || snapshot.phase == .checking
        // An externally started Harness stays controllable, but the menu labels
        // say so and the action asks for confirmation naming the process.
        let externallyStarted = snapshot.isRunning && !snapshot.isManaged
        toggleServiceMenuItem.isEnabled = !busy
        restartMenuItem.isEnabled = snapshot.isRunning && !busy
        openWebMenuItem.isEnabled = snapshot.isRunning
        copyUrlMenuItem.isEnabled = snapshot.isRunning

        switch snapshot.phase {
        case .running where externallyStarted:
            toggleServiceMenuItem.title = "Stop External Service…"
            restartMenuItem.title = "Adopt & Restart Service…"
        case .running:
            toggleServiceMenuItem.title = "Stop Service"
            restartMenuItem.title = "Restart Service"
        case .portConflict, .error:
            toggleServiceMenuItem.title = "Retry Start"
            restartMenuItem.title = "Restart Service"
        default:
            toggleServiceMenuItem.title = "Start Service"
            restartMenuItem.title = "Restart Service"
        }

        // Keep the recovery notice in the tooltip too: it survives an
        // automatic restart, which the status line alone would hide.
        let base = statusTitle(for: snapshot)
        statusItem.button?.toolTip = ServiceManager.shared.recoveryNotice.map { "\(base) — \($0)" } ?? base

        // Nothing of ours is running, so there is nothing to stop on the way out.
        quitAndStopMenuItem.isEnabled = snapshot.isRunning && snapshot.isManaged
    }

    @objc private func didSelectOpenWeb() {
        ServiceManager.shared.openBrowser()
    }

    @objc private func didSelectToggleService() {
        let snapshot = ServiceManager.shared.snapshot
        if snapshot.isRunning {
            if ServiceManager.shared.hasUnmanagedService, let pid = snapshot.pid {
                ExternalServicePrompt.confirm(action: .stop) { [weak self] confirmed in
                    guard confirmed else { return }
                    ServiceManager.shared.stopUnmanagedService(pid: pid) { [weak self] success, message in
                        if !success, let message {
                            self?.showAlert(title: "Could Not Stop the External Service", message: message)
                        }
                    }
                }
                return
            }
            ServiceManager.shared.stopService { [weak self] success, message in
                if !success, let message {
                    self?.showAlert(title: "Could Not Stop the Service", message: message)
                }
            }
        } else {
            ServiceManager.shared.startService { [weak self] success, message in
                if !success, let message {
                    self?.handleStartFailure(message)
                }
            }
        }
    }

    @objc private func didSelectRestart() {
        let snapshot = ServiceManager.shared.snapshot
        if ServiceManager.shared.hasUnmanagedService, let pid = snapshot.pid {
            ExternalServicePrompt.confirm(action: .restart) { [weak self] confirmed in
                guard confirmed else { return }
                ServiceManager.shared.restartUnmanagedService(pid: pid) { [weak self] success, message in
                    if !success, let message {
                        self?.showAlert(title: "Could Not Restart the External Service", message: message)
                    }
                }
            }
            return
        }
        ServiceManager.shared.restartService { [weak self] success, message in
            if !success, let message {
                self?.showAlert(title: "Could Not Restart the Service", message: message)
            }
        }
    }

    private func handleStartFailure(_ message: String) {
        if ServiceManager.shared.snapshot.dshPath == nil {
            DshInstallAssistant.present()
        } else {
            showAlert(title: "Could Not Start the Service", message: message)
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
        LogWindowController.shared.showWindow(nil)
    }

    @objc private func didSelectQuit() {
        // Default: the service DSH Bar started keeps running, and the managed
        // record stays on disk so a later launch re-adopts it.
        NSApplication.shared.terminate(nil)
    }

    @objc private func didSelectQuitAndStopService() {
        let snapshot = ServiceManager.shared.snapshot
        // Only a service we started is ours to stop. For anything else, say so
        // instead of quietly doing nothing, then quit with the service intact.
        guard snapshot.isRunning, snapshot.isManaged else {
            NSApplication.shared.terminate(nil)
            return
        }
        pendingQuitStopsService = true
        NSApplication.shared.terminate(nil)
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
