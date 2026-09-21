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
    private let serviceDetailsLabel = NSTextField(labelWithString: "Checking service details…")
    
    // Preferences UI
    private let portField = NSTextField()
    private let portResetButton = NSButton()
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let hotKeyButton = NSButton()
    private let hotKeyResetButton = NSButton()
    private let dshInfoLabel = NSTextField(labelWithString: "Detecting DSH CLI…")
    private let dshActionButton = NSButton()
    
    private var localEventMonitor: Any?
    private var isRecordingHotKey = false
    private var copyFeedbackTimer: Timer?
    private var statusObserverToken: UUID?
    private var portObserverToken: UUID?
    
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 630),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Preferences"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // Float only while the panel is focused. Losing focus drops it back to
        // the normal level so it no longer covers whatever the user switches to.
        window.level = .floating
        window.backgroundColor = .clear
        
        super.init(window: window)
        setupUI()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )

        // Subscribe independently: the panel and the menu bar each receive every
        // status/port change. Previously these were single callback slots, so the
        // panel overwrote the menu bar's closure and the menu went stale.
        statusObserverToken = ServiceManager.shared.addStatusObserver { [weak self] snapshot in
            self?.updateState(snapshot)
        }
        portObserverToken = SettingsManager.shared.addPortObserver { [weak self] port in
            self?.updateUrlDisplay(port: port)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func panelDidBecomeKey() {
        window?.level = .floating
    }

    @objc private func panelDidResignKey() {
        guard window?.isVisible == true else { return }
        window?.level = .normal
    }
    
    override func showWindow(_ sender: Any?) {
        // Always reflect the latest state when the panel is brought up.
        updateState(ServiceManager.shared.snapshot)
        ServiceManager.shared.detectDshInstallation()
        // Re-float explicitly: the panel may have been dropped to the normal
        // level when it lost focus before being closed.
        window?.level = .floating
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
    
    private func setupUI() {
        guard let window = self.window else { return }

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        window.contentView = visualEffect

        let header = makeHeaderView()
        let serviceCard = makeServiceCard()
        let preferencesCard = makePreferencesCard()
        let footer = makeFooterView()
        [header, serviceCard, preferencesCard, footer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            visualEffect.addSubview($0)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 34),
            header.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -24),
            header.heightAnchor.constraint(equalToConstant: 72),

            serviceCard.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            serviceCard.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            serviceCard.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            serviceCard.heightAnchor.constraint(equalToConstant: 160),

            preferencesCard.topAnchor.constraint(equalTo: serviceCard.bottomAnchor, constant: 14),
            preferencesCard.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            preferencesCard.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            preferencesCard.heightAnchor.constraint(equalToConstant: 270),

            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor, constant: -18),
            footer.heightAnchor.constraint(equalToConstant: 32)
        ])

        updateUrlDisplay(port: SettingsManager.shared.port)
    }

    private func makeHeaderView() -> NSView {
        let header = NSView()

        let iconView = NSImageView()
        if let iconPath = Bundle.main.path(forResource: "icon", ofType: "png"),
           let icon = NSImage(contentsOfFile: iconPath) {
            iconView.image = icon
        } else {
            iconView.image = NSApplication.shared.applicationIconImage
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(iconView)

        let titleLabel = makeLabel("DeepSeek Harness", size: 20, weight: .bold)
        // Inside the app bundle this always resolves; the fallback only shows up
        // in tooling that runs the sources without an Info.plist.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
        let subtitleLabel = makeLabel("Menu Bar Companion  •  v\(version)", size: 12, weight: .medium, color: .secondaryLabelColor)
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addSubview(titleStack)

        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.boxType = .custom
        statusBadge.cornerRadius = 14
        statusBadge.borderWidth = 1
        header.addSubview(statusBadge)

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.boxType = .custom
        statusDot.cornerRadius = 5
        statusDot.borderWidth = 0
        statusBadge.addSubview(statusDot)

        statusText.translatesAutoresizingMaskIntoConstraints = false
        statusText.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        statusText.lineBreakMode = .byTruncatingTail
        statusBadge.addSubview(statusText)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),

            titleStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            titleStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: statusBadge.leadingAnchor, constant: -12),

            statusBadge.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -4),
            statusBadge.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusBadge.widthAnchor.constraint(equalToConstant: 150),
            statusBadge.heightAnchor.constraint(equalToConstant: 28),

            statusDot.leadingAnchor.constraint(equalTo: statusBadge.leadingAnchor, constant: 11),
            statusDot.centerYAnchor.constraint(equalTo: statusBadge.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),

            statusText.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 7),
            statusText.trailingAnchor.constraint(equalTo: statusBadge.trailingAnchor, constant: -10),
            statusText.centerYAnchor.constraint(equalTo: statusBadge.centerYAnchor)
        ])

        return header
    }

    private func makeServiceCard() -> NSView {
        let card = makeCardView()
        let title = makeSectionTitle("LOCAL WEB CONSOLE")
        card.addSubview(title)

        let urlContainer = makeInsetView()
        urlContainer.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(urlContainer)

        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        urlLabel.textColor = .labelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlContainer.addSubview(urlLabel)

        copyButton.title = "Copy"
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(didClickCopy)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        urlContainer.addSubview(copyButton)

        serviceDetailsLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        serviceDetailsLabel.textColor = .secondaryLabelColor
        serviceDetailsLabel.lineBreakMode = .byTruncatingTail
        serviceDetailsLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(serviceDetailsLabel)

        configureActionButton(openButton, title: "Open Web", action: #selector(didClickOpen))
        openButton.keyEquivalent = "\r"
        configureActionButton(toggleButton, title: "Start Service", action: #selector(didClickToggle))
        configureActionButton(restartButton, title: "Restart", action: #selector(didClickRestart))

        let actions = NSStackView(views: [openButton, toggleButton, restartButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.distribution = .fillEqually
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(actions)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 15),
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -18),

            urlContainer.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 9),
            urlContainer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            urlContainer.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            urlContainer.heightAnchor.constraint(equalToConstant: 40),

            urlLabel.leadingAnchor.constraint(equalTo: urlContainer.leadingAnchor, constant: 14),
            urlLabel.centerYAnchor.constraint(equalTo: urlContainer.centerYAnchor),
            urlLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -10),

            copyButton.trailingAnchor.constraint(equalTo: urlContainer.trailingAnchor, constant: -8),
            copyButton.centerYAnchor.constraint(equalTo: urlContainer.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 68),
            copyButton.heightAnchor.constraint(equalToConstant: 26),

            serviceDetailsLabel.topAnchor.constraint(equalTo: urlContainer.bottomAnchor, constant: 8),
            serviceDetailsLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            serviceDetailsLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),

            actions.topAnchor.constraint(greaterThanOrEqualTo: serviceDetailsLabel.bottomAnchor, constant: 8),
            actions.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            actions.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            actions.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -13),
            actions.heightAnchor.constraint(equalToConstant: 32)
        ])

        return card
    }

    private func makePreferencesCard() -> NSView {
        let card = makeCardView()
        let title = makeSectionTitle("PREFERENCES & CONFIGURATION")
        card.addSubview(title)

        let portRow = NSView()
        portRow.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(portRow)

        let portText = makeTextStack(title: "Server Port", description: "Default: 3080")
        portRow.addSubview(portText)

        portField.stringValue = "\(SettingsManager.shared.port)"
        portField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        portField.alignment = .center
        portField.delegate = self
        portField.translatesAutoresizingMaskIntoConstraints = false

        portResetButton.title = "Default"
        portResetButton.bezelStyle = .rounded
        portResetButton.controlSize = .small
        portResetButton.target = self
        portResetButton.action = #selector(didResetPort)
        portResetButton.translatesAutoresizingMaskIntoConstraints = false

        let portControls = NSStackView(views: [portField, portResetButton])
        portControls.orientation = .horizontal
        portControls.alignment = .centerY
        portControls.spacing = 8
        portControls.translatesAutoresizingMaskIntoConstraints = false
        portRow.addSubview(portControls)

        let separator1 = makeSeparator()
        card.addSubview(separator1)

        let shortcutRow = NSView()
        shortcutRow.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(shortcutRow)

        let shortcutText = makeTextStack(title: "Global Shortcut", description: "Open the Web console from anywhere")
        shortcutRow.addSubview(shortcutText)

        hotKeyButton.title = SettingsManager.shared.globalHotKeyDisplayString
        hotKeyButton.bezelStyle = .rounded
        hotKeyButton.target = self
        hotKeyButton.action = #selector(didClickRecordHotKey)
        hotKeyButton.translatesAutoresizingMaskIntoConstraints = false

        hotKeyResetButton.title = "Reset"
        hotKeyResetButton.bezelStyle = .rounded
        hotKeyResetButton.controlSize = .small
        hotKeyResetButton.target = self
        hotKeyResetButton.action = #selector(didClickResetHotKey)
        hotKeyResetButton.translatesAutoresizingMaskIntoConstraints = false

        let shortcutControls = NSStackView(views: [hotKeyButton, hotKeyResetButton])
        shortcutControls.orientation = .horizontal
        shortcutControls.alignment = .centerY
        shortcutControls.spacing = 8
        shortcutControls.translatesAutoresizingMaskIntoConstraints = false
        shortcutRow.addSubview(shortcutControls)

        let separator2 = makeSeparator()
        card.addSubview(separator2)

        let loginRow = NSView()
        loginRow.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(loginRow)

        let loginText = makeTextStack(
            title: "Launch at Login",
            description: "Start quietly in the menu bar; keep the Web console closed"
        )
        loginRow.addSubview(loginText)

        launchAtLoginCheckbox.state = SettingsManager.shared.isLaunchAtLoginEnabled ? .on : .off
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(didToggleLaunchAtLogin)
        launchAtLoginCheckbox.translatesAutoresizingMaskIntoConstraints = false
        loginRow.addSubview(launchAtLoginCheckbox)

        let separator3 = makeSeparator()
        card.addSubview(separator3)

        let dshRow = NSView()
        dshRow.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(dshRow)

        let dshTitleLabel = makeLabel("DSH Command Line", size: 13, weight: .medium)
        dshInfoLabel.font = NSFont.systemFont(ofSize: 11)
        dshInfoLabel.textColor = .secondaryLabelColor
        dshInfoLabel.lineBreakMode = .byTruncatingMiddle
        dshInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        let dshText = NSStackView(views: [dshTitleLabel, dshInfoLabel])
        dshText.orientation = .vertical
        dshText.alignment = .leading
        dshText.spacing = 1
        dshText.translatesAutoresizingMaskIntoConstraints = false
        dshText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dshRow.addSubview(dshText)

        dshActionButton.title = "Recheck"
        dshActionButton.bezelStyle = .rounded
        dshActionButton.controlSize = .small
        dshActionButton.target = self
        dshActionButton.action = #selector(didClickDshAction)
        dshActionButton.translatesAutoresizingMaskIntoConstraints = false
        dshRow.addSubview(dshActionButton)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 15),
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -18),

            portRow.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),
            portRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            portRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            portRow.heightAnchor.constraint(equalToConstant: 54),

            portText.leadingAnchor.constraint(equalTo: portRow.leadingAnchor),
            portText.centerYAnchor.constraint(equalTo: portRow.centerYAnchor),
            portText.trailingAnchor.constraint(lessThanOrEqualTo: portControls.leadingAnchor, constant: -12),
            portControls.trailingAnchor.constraint(equalTo: portRow.trailingAnchor),
            portControls.centerYAnchor.constraint(equalTo: portRow.centerYAnchor),
            portField.widthAnchor.constraint(equalToConstant: 76),
            portField.heightAnchor.constraint(equalToConstant: 26),
            portResetButton.widthAnchor.constraint(equalToConstant: 68),
            portResetButton.heightAnchor.constraint(equalToConstant: 26),

            separator1.topAnchor.constraint(equalTo: portRow.bottomAnchor),
            separator1.leadingAnchor.constraint(equalTo: portRow.leadingAnchor),
            separator1.trailingAnchor.constraint(equalTo: portRow.trailingAnchor),
            separator1.heightAnchor.constraint(equalToConstant: 1),

            shortcutRow.topAnchor.constraint(equalTo: separator1.bottomAnchor),
            shortcutRow.leadingAnchor.constraint(equalTo: portRow.leadingAnchor),
            shortcutRow.trailingAnchor.constraint(equalTo: portRow.trailingAnchor),
            shortcutRow.heightAnchor.constraint(equalToConstant: 60),

            shortcutText.leadingAnchor.constraint(equalTo: shortcutRow.leadingAnchor),
            shortcutText.centerYAnchor.constraint(equalTo: shortcutRow.centerYAnchor),
            shortcutText.trailingAnchor.constraint(lessThanOrEqualTo: shortcutControls.leadingAnchor, constant: -12),
            shortcutControls.trailingAnchor.constraint(equalTo: shortcutRow.trailingAnchor),
            shortcutControls.centerYAnchor.constraint(equalTo: shortcutRow.centerYAnchor),
            hotKeyButton.widthAnchor.constraint(equalToConstant: 118),
            hotKeyButton.heightAnchor.constraint(equalToConstant: 30),
            hotKeyResetButton.widthAnchor.constraint(equalToConstant: 60),
            hotKeyResetButton.heightAnchor.constraint(equalToConstant: 26),

            separator2.topAnchor.constraint(equalTo: shortcutRow.bottomAnchor),
            separator2.leadingAnchor.constraint(equalTo: portRow.leadingAnchor),
            separator2.trailingAnchor.constraint(equalTo: portRow.trailingAnchor),
            separator2.heightAnchor.constraint(equalToConstant: 1),

            loginRow.topAnchor.constraint(equalTo: separator2.bottomAnchor),
            loginRow.leadingAnchor.constraint(equalTo: portRow.leadingAnchor),
            loginRow.trailingAnchor.constraint(equalTo: portRow.trailingAnchor),
            loginRow.heightAnchor.constraint(equalToConstant: 54),

            loginText.leadingAnchor.constraint(equalTo: loginRow.leadingAnchor),
            loginText.centerYAnchor.constraint(equalTo: loginRow.centerYAnchor),
            loginText.trailingAnchor.constraint(lessThanOrEqualTo: launchAtLoginCheckbox.leadingAnchor, constant: -12),
            launchAtLoginCheckbox.trailingAnchor.constraint(equalTo: loginRow.trailingAnchor),
            launchAtLoginCheckbox.centerYAnchor.constraint(equalTo: loginRow.centerYAnchor),

            separator3.topAnchor.constraint(equalTo: loginRow.bottomAnchor),
            separator3.leadingAnchor.constraint(equalTo: portRow.leadingAnchor),
            separator3.trailingAnchor.constraint(equalTo: portRow.trailingAnchor),
            separator3.heightAnchor.constraint(equalToConstant: 1),

            dshRow.topAnchor.constraint(equalTo: separator3.bottomAnchor),
            dshRow.leadingAnchor.constraint(equalTo: portRow.leadingAnchor),
            dshRow.trailingAnchor.constraint(equalTo: portRow.trailingAnchor),
            dshRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),

            dshText.leadingAnchor.constraint(equalTo: dshRow.leadingAnchor),
            dshText.centerYAnchor.constraint(equalTo: dshRow.centerYAnchor),
            dshText.trailingAnchor.constraint(lessThanOrEqualTo: dshActionButton.leadingAnchor, constant: -12),
            dshActionButton.trailingAnchor.constraint(equalTo: dshRow.trailingAnchor),
            dshActionButton.centerYAnchor.constraint(equalTo: dshRow.centerYAnchor),
            dshActionButton.widthAnchor.constraint(equalToConstant: 78),
            dshActionButton.heightAnchor.constraint(equalToConstant: 26)
        ])

        return card
    }

    private func makeFooterView() -> NSView {
        let footer = NSView()

        logsButton.title = "View Live Logs"
        logsButton.bezelStyle = .accessoryBarAction
        logsButton.target = self
        logsButton.action = #selector(didClickLogs)
        logsButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(logsButton)

        let tipLabel = makeLabel("Preferences: ⌘,  •  Close: Esc", size: 11, color: .tertiaryLabelColor)
        tipLabel.alignment = .right
        footer.addSubview(tipLabel)

        let closeButton = NSButton(title: "Done", target: self, action: #selector(didClickClose))
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(closeButton)

        NSLayoutConstraint.activate([
            logsButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            logsButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            logsButton.widthAnchor.constraint(equalToConstant: 120),
            logsButton.heightAnchor.constraint(equalToConstant: 30),

            closeButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 74),
            closeButton.heightAnchor.constraint(equalToConstant: 30),

            tipLabel.leadingAnchor.constraint(greaterThanOrEqualTo: logsButton.trailingAnchor, constant: 12),
            tipLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -12),
            tipLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])

        return footer
    }

    private func makeCardView() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.backgroundColor = NSColor.textColor.withAlphaComponent(0.04).cgColor
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        view.layer?.borderWidth = 1
        return view
    }

    private func makeInsetView() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.backgroundColor = NSColor.textColor.withAlphaComponent(0.06).cgColor
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        view.layer?.borderWidth = 1
        return view
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        return separator
    }

    private func makeSectionTitle(_ text: String) -> NSTextField {
        makeLabel(text, size: 11, weight: .bold, color: .tertiaryLabelColor)
    }

    private func makeTextStack(title: String, description: String) -> NSStackView {
        let titleLabel = makeLabel(title, size: 13, weight: .medium)
        let descriptionLabel = makeLabel(description, size: 11, color: .secondaryLabelColor)
        descriptionLabel.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [titleLabel, descriptionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }

    private func makeLabel(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func configureActionButton(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func updateUrlDisplay(port configuredPort: Int) {
        let activePort = ServiceManager.shared.snapshot.isRunning
            ? ServiceManager.shared.snapshot.port
            : configuredPort
        urlLabel.stringValue = "http://127.0.0.1:\(activePort)"
        portField.stringValue = "\(configuredPort)"
    }
    
    func updateState(_ snapshot: ServiceSnapshot) {
        let color: NSColor
        switch snapshot.phase {
        case .running:
            color = .systemGreen
            statusText.stringValue = "RUNNING : \(snapshot.port)"
        case .checking:
            color = .systemOrange
            statusText.stringValue = "CHECKING"
        case .starting:
            color = .systemOrange
            statusText.stringValue = "STARTING"
        case .stopping:
            color = .systemOrange
            statusText.stringValue = "STOPPING"
        case .restarting:
            color = .systemOrange
            statusText.stringValue = "RESTARTING"
        case .portConflict:
            color = .systemRed
            statusText.stringValue = "PORT IN USE"
        case .error:
            color = .systemRed
            statusText.stringValue = "ERROR"
        case .stopped:
            color = .secondaryLabelColor
            statusText.stringValue = "STOPPED"
        }

        statusBadge.fillColor = color.withAlphaComponent(0.15)
        statusBadge.borderColor = color.withAlphaComponent(0.4)
        statusDot.fillColor = color
        statusText.textColor = color

        var details: [String] = []
        if let pid = snapshot.pid { details.append("PID \(pid)") }
        if let uptime = snapshot.uptime { details.append("Up \(Self.formatDuration(uptime))") }
        if let version = snapshot.dshVersion { details.append("DSH \(version)") }
        if let message = snapshot.message { details.append(message) }
        if details.isEmpty {
            details.append(snapshot.phase == .stopped ? "Service is not running" : "Checking service status…")
        }
        serviceDetailsLabel.stringValue = details.joined(separator: "  •  ")

        let busy = snapshot.phase.isBusy || snapshot.phase == .checking
        // A service started outside DSH Bar stays fully controllable, but every
        // action on it goes through a confirmation that names the exact process.
        let externallyStarted = snapshot.isRunning && !snapshot.isManaged
        openButton.isEnabled = snapshot.isRunning
        restartButton.isEnabled = snapshot.isRunning && !busy
        toggleButton.isEnabled = !busy
        // Editing the port mid-operation would desync the in-flight target port.
        portField.isEnabled = !busy
        portResetButton.isEnabled = !busy
        switch snapshot.phase {
        case .running where externallyStarted:
            toggleButton.title = "Stop External…"
            restartButton.title = "Adopt & Restart"
        case .running:
            toggleButton.title = "Stop Service"
            restartButton.title = "Restart"
        case .portConflict, .error:
            toggleButton.title = "Retry Start"
            restartButton.title = "Restart"
        default:
            toggleButton.title = "Start Service"
            restartButton.title = "Restart"
        }

        if !ServiceManager.shared.dshDetectionComplete {
            dshInfoLabel.stringValue = "Searching PATH with which dsh…"
            dshActionButton.title = "Checking…"
            dshActionButton.isEnabled = false
        } else if let path = snapshot.dshPath {
            let version = snapshot.dshVersion.map { " • \($0)" } ?? ""
            dshInfoLabel.stringValue = "Installed: \(path)\(version)"
            dshActionButton.title = "Recheck"
            dshActionButton.isEnabled = true
        } else {
            dshInfoLabel.stringValue = "Not found — install with npm to start the service"
            dshActionButton.title = "Install…"
            dshActionButton.isEnabled = true
        }

        updateUrlDisplay(port: SettingsManager.shared.port)
    }
    
    // MARK: - Actions
    @objc private func didClickOpen() {
        ServiceManager.shared.openBrowser()
    }
    
    @objc private func didClickToggle() {
        if ServiceManager.shared.isRunning {
            if ServiceManager.shared.hasUnmanagedService {
                guard let pid = ServiceManager.shared.snapshot.pid else { return }
                ExternalServicePrompt.confirm(action: .stop) { [weak self] confirmed in
                    guard confirmed else { return }
                    self?.stopUnmanagedService(pid: pid)
                }
                return
            }
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
                if !success, ServiceManager.shared.snapshot.dshPath == nil {
                    DshInstallAssistant.present()
                } else if !success, let message = message {
                    self?.showAlert(title: "Could Not Start the Service", message: message)
                }
            }
        }
    }

    private func stopUnmanagedService(pid: Int32) {
        toggleButton.isEnabled = false
        ServiceManager.shared.stopUnmanagedService(pid: pid) { [weak self] success, message in
            self?.toggleButton.isEnabled = true
            if !success, let message = message {
                self?.showAlert(title: "Could Not Stop the External Service", message: message)
            }
        }
    }

    @objc private func didClickRestart() {
        if ServiceManager.shared.hasUnmanagedService {
            guard let pid = ServiceManager.shared.snapshot.pid else { return }
            ExternalServicePrompt.confirm(action: .restart) { [weak self] confirmed in
                guard confirmed else { return }
                self?.restartUnmanagedService(pid: pid)
            }
            return
        }
        restartButton.isEnabled = false
        ServiceManager.shared.restartService { [weak self] success, message in
            self?.restartButton.isEnabled = true
            if !success, let message = message {
                self?.showAlert(title: "Could Not Restart the Service", message: message)
            }
        }
    }

    private func restartUnmanagedService(pid: Int32) {
        restartButton.isEnabled = false
        ServiceManager.shared.restartUnmanagedService(pid: pid) { [weak self] success, message in
            self?.restartButton.isEnabled = true
            if !success, let message = message {
                self?.showAlert(title: "Could Not Restart the External Service", message: message)
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
        LogWindowController.shared.showWindow(nil)
    }

    @objc private func didClickDshAction() {
        if ServiceManager.shared.snapshot.dshPath == nil {
            DshInstallAssistant.present()
        } else {
            dshActionButton.isEnabled = false
            dshActionButton.title = "Checking…"
            ServiceManager.shared.detectDshInstallation { [weak self] _ in
                self?.dshActionButton.isEnabled = true
            }
        }
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
        // A lifecycle operation captures its target port up front; accepting an
        // edit now would make the running and configured ports diverge mid-flight.
        guard !ServiceManager.shared.snapshot.phase.isBusy else {
            portField.stringValue = "\(SettingsManager.shared.port)"
            return
        }
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
    
    private static func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    // MARK: - Preferences Actions
    @objc private func didToggleLaunchAtLogin() {
        let enabled = (launchAtLoginCheckbox.state == .on)
        SettingsManager.shared.isLaunchAtLoginEnabled = enabled
    }
    
    @objc private func didClickClose() {
        if isRecordingHotKey {
            stopRecording(cancelled: true)
        }
        self.window?.orderOut(nil)
    }
}
