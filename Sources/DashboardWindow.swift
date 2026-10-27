import Cocoa
import Carbon
import ServiceManagement

private final class DashboardPanelWindow: NSWindow {
    var onCommandW: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "w" {
            onCommandW?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCommandW?()
    }
}

/// What the install-channel row should currently say and which of its controls
/// are live. Kept as a value so the decision can be tested without a window.
struct TagRowPresentation: Equatable {
    var title: String
    var description: String
    var popupTitle: String          // "" while loading; the selected item otherwise
    var popupEnabled: Bool
    var installButtonTitle: String
    var installButtonEnabled: Bool
    var showsRestartNotice: Bool
}

/// The single source of truth for the install-channel row's appearance.
///
/// Pure: every input is a parameter, so the truth table in
/// `Tests/tag-probe-check.sh` can pin every state the row can be in. Reading
/// the stored preference and the controller's busy flag are the only two reads
/// of app state, and both are read-only.
func tagRowPresentation(
    state: ProbeState,
    installedTag: String?,
    isRunning: Bool,
    pendingRestart: Bool,
    installActivity: InstallActivity? = nil,
    allowsRetry: Bool = false
) -> TagRowPresentation {
    let options = state.options()
    let title = L(.installChannel)

    let installing = installActivity != nil
    let button = installing ? L(.installingEllipsis)
        : (state.isLoading ? L(.checkingEllipsis) : L(.installEllipsis))

    var titles = [String]()
    titles.reserveCapacity(options.count)
    for option in options {
        // Built by substituting into the localized template the way
        // Localization.string does, so the "(installed)" marker is translatable
        // rather than a hardcoded String(format:).
        var line = L(.tagInstalledSuffix)
        for (name, value) in ["tag": option.tag, "version": option.version] {
            line = line.replacingOccurrences(of: "{\(name)}", with: value)
        }
        titles.append(option.isInstalled ? line : option.tag)
    }

    let selected = SettingsManager.shared.preferredDshTag
    let selection = options.firstIndex { $0.tag == selected } ?? 0
    let popupTitle = titles.indices.contains(selection) ? titles[selection] : ""
    // A cancelled npm run may have partially changed the on-disk installation.
    // Keep retry available even when the registry offers only its current tag.
    let hasOtherChannel = options.contains { $0.tag != installedTag }

    // A failed probe has nothing to offer, so its reason takes over the
    // description: a dropdown that simply vanished reads as a broken app rather
    // than an unreachable network. The reason outranks the pending-restart
    // notice because a failure is what the user has to act on.
    let restingDescription = pendingRestart
        ? L(.installDoneRestartNotice)
        : (isRunning ? L(.portChangedAppliesLater) : L(.installChannelDesc))

    return TagRowPresentation(
        title: title,
        // The running-service wording is deliberately generic: this row also
        // covers an install performed while the service was stopped, and
        // .portChangedRestartToApply ("Restart to Apply") would be a lie
        // there. The full sentence lives in the confirmation dialog.
        description: installing ? L(.installingEllipsis) : (state.failure?.message ?? restingDescription),
        popupTitle: popupTitle,
        popupEnabled: !installing && !options.isEmpty,
        installButtonTitle: button,
        installButtonEnabled: !installing && !options.isEmpty && (hasOtherChannel || allowsRetry),
        showsRestartNotice: pendingRestart && !installing
    )
}

struct InstallProgressPresentation: Equatable {
    let title: String
    let metrics: String
    let fraction: Double?
    let canCancel: Bool
}

/// Download metrics describe only the principal archive, never npm dependencies.
func installProgressPresentation(activity: InstallActivity, now: TimeInterval) -> InstallProgressPresentation {
    let title: String
    switch activity.phase {
    case .resolving: title = L(.installResolving, ["tag": activity.tag])
    case .downloading: title = L(.installDownloading)
    case .verifying: title = L(.installVerifying)
    case .installing: title = L(.installDependencies)
    case .cancelling: title = L(.installCancelling)
    }
    var metrics = [L(.installElapsed, ["elapsed": activity.elapsed(at: now)])]
    var fraction: Double?
    if activity.phase == .downloading {
        let received = max(0, activity.bytesReceived)
        let size = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        if let total = activity.totalBytes, total > 0 {
            fraction = min(1, Double(received) / Double(total))
            let totalSize = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            metrics.insert("\(size) / \(totalSize) · \(Int(fraction! * 100))%", at: 0)
        } else {
            metrics.insert(L(.installSizeUnknown, ["size": size]), at: 0)
        }
        let rate = activity.bytesPerSecond
        if rate.isFinite && rate >= 1 && rate < Double(Int64.max) {
            metrics.insert(ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file) + "/s", at: 1)
            if let total = activity.totalBytes, total > received {
                let remaining = Double(total - received) / rate
                if remaining.isFinite && remaining >= 1 && remaining < 86400 {
                    let seconds = Int(remaining.rounded(.up))
                    metrics.append(L(.installRemaining, ["time": String(format: "%d:%02d", seconds / 60, seconds % 60)]))
                }
            }
        } else {
            metrics.insert(L(.installWaiting), at: 1)
        }
    }
    return InstallProgressPresentation(
        title: activity.version.map { "\(title) · \($0)" } ?? title,
        metrics: metrics.joined(separator: "  ·  "),
        fraction: fraction,
        canCancel: activity.phase != .cancelling
    )
}

final class DashboardWindowController: NSWindowController, NSTextFieldDelegate {
    static let shared = DashboardWindowController()

    private static let naturalContentHeight: CGFloat = 540

    // Status Badge UI
    private let statusBadge = NSBox()
    private let statusDot = NSBox()
    private let statusText = NSTextField(labelWithString: L(.statusStoppedWord))
    
    // URL Bar UI
    private let urlLabel = NSTextField(labelWithString: "http://127.0.0.1:3080")
    private let copyButton = NSButton()
    
    // Action Buttons
    private let openButton = NSButton()
    private let toggleButton = NSButton()
    private let restartButton = NSButton()
    private let logsButton = NSButton()
    private let diagnosticsButton = NSButton()
    private let serviceDetailsLabel = NSTextField(labelWithString: L(.checkingServiceDetails))
    
    // Preferences UI
    private let portField = NSTextField()
    private let portResetButton = NSButton()
    private let launchAtLoginCheckbox = NSSwitch()
    private let hotKeyButton = NSButton()
    private let hotKeyResetButton = NSButton()
    private let dshInfoLabel = NSTextField(labelWithString: L(.detectingDsh))
    private let dshActionButton = NSButton()
    // Install-channel row. `tagInfoLabel` is the description under the row's
    // title; it is held here rather than reached through the stack view that
    // `makeTextStack` builds, the way `notificationInfoLabel` is, because
    // `setupUI()` rebuilds that stack on every language change while these
    // properties survive it.
    private let tagPopup = NSPopUpButton()
    private let tagInstallButton = NSButton()
    private let tagInfoLabel = NSTextField(labelWithString: "")
    private let tagInstallProgress = NSProgressIndicator()
    private let tagInstallStatusLabel = NSTextField(labelWithString: "")
    private var tagInstallTimer: Timer?
    private let installTaskStack = NSStackView()
    private let tagInstallMetricsLabel = NSTextField(wrappingLabelWithString: "")
    private let tagCancelButton = NSButton()
    private let tagDetailsButton = NSButton()
    private let tagLogScroll = NSScrollView()
    private let tagLogText = NSTextView()
    private var showsInstallDetails = false
    private var installOutcome: Localization.Key?

    /// Last probe result; the row re-renders from it whenever anything changes.
    private var tagProbeState: ProbeState = .idle
    /// The channel currently on disk, resolved from the last successful probe.
    private var installedTagName: String?
    /// Set after a successful install, cleared when the service restarts.
    private var pendingTagRestart = false
    /// Whether the service was running when an install succeeded, so the
    /// restart notice knows what the user has to do. See `clearPendingTagRestart`.
    private var tagRestartFromRunning = false
    /// The running state the previous `updateState` tick saw. `updateState` runs
    /// every ~2s, so "the service restarted" has to be an edge, not a level.
    private var lastTagServiceRunning = false
    // Software Updates row. `updateInfoLabel` is the live version line, held
    // here rather than in the stack `makeTextStack` builds for the same reason
    // `tagInfoLabel` is: the language-change rebuild in `setupUI()` recreates
    // that stack while these properties survive it.
    private let updateInfoLabel = NSTextField(labelWithString: "")
    private let updateCheckButton = NSButton()
    private let autoUpdateCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let autoRestartCheckbox = NSSwitch()
    private let notificationInfoLabel = NSTextField(labelWithString: L(.notifNotChecked))
    private let notificationActionButton = NSButton()
    private let languagePopup = NSPopUpButton()
    private var languageObserverToken: UUID?
    /// Guards against rebuilding the panel twice for one effective language.
    private var lastEffectiveLanguage: AppLanguage = Localization.shared.effective
    
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var isRecordingHotKey = false
    private var copyFeedbackTimer: Timer?
    private var statusObserverToken: UUID?
    private var portObserverToken: UUID?
    private var notifierObserverToken: UUID?
    
    init() {
        let window = DashboardPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 800),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = L(.windowTitlePreferences)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // Float only while the panel is focused. Losing focus drops it back to
        // the normal level so it no longer covers whatever the user switches to.
        window.level = .floating
        window.backgroundColor = .clear
        // The entire settings document scrolls, including the service section.
        window.minSize = NSSize(width: 540, height: Self.naturalContentHeight)
        window.maxSize = NSSize(width: 900, height: 1200)

        super.init(window: window)

        window.onCommandW = { [weak self] in
            self?.didClickClose()
        }

        setupUI()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stopInstallProgress),
            name: NSWindow.willCloseNotification,
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
        // Notification availability can change while the panel is open, so the
        // recovery row has to follow it rather than only refreshing on reopen.
        notifierObserverToken = ServiceNotifier.shared.addObserver { [weak self] in
            self?.updateNotificationRow()
        }
        languageObserverToken = Localization.shared.addObserver { [weak self] in
            self?.rebuildForLanguage()
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        tagInstallTimer?.invalidate()
        if let token = notifierObserverToken {
            ServiceNotifier.shared.removeObserver(token)
        }
        if let token = languageObserverToken {
            Localization.shared.removeObserver(token)
        }
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
        updateNotificationRow()
        // Registration can have failed while the panel was closed, e.g. another
        // app took the shortcut in the meantime.
        hotKeyButton.title = SettingsManager.shared.globalHotKeyDisplayString
        updateHotKeyAppearance()
        autoRestartCheckbox.state = SettingsManager.shared.autoRestartEnabled ? .on : .off
        ServiceManager.shared.detectDshInstallation()
        loadTagOptions()
        // Re-float explicitly: the panel may have been dropped to the normal
        // level when it lost focus before being closed.
        window?.level = .floating
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        refreshTagRow()
    }
    
    private func setupUI() {
        guard let window else { return }
        let background = NSView()
        window.backgroundColor = .windowBackgroundColor
        window.contentView = background

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scroll)

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let header = makeHeaderView()
        let service = makeServiceCard()
        let preferences = makePreferencesCard()
        let contents = NSStackView(views: [header, service, preferences])
        contents.orientation = .vertical
        contents.alignment = .leading
        contents.spacing = 16
        contents.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(contents)
        let footer = makeFooterView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: 30),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            contents.topAnchor.constraint(equalTo: document.topAnchor, constant: 14),
            contents.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            contents.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            contents.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: contents.widthAnchor),
            header.heightAnchor.constraint(equalToConstant: 60),
            service.widthAnchor.constraint(equalTo: contents.widthAnchor),
            service.heightAnchor.constraint(equalToConstant: 160),
            preferences.widthAnchor.constraint(equalTo: contents.widthAnchor),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -16),
            footer.heightAnchor.constraint(equalToConstant: 30)
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

        let titleLabel = makeLabel(L(.appName), size: 18, weight: .semibold)
        // Inside the app bundle this always resolves; the fallback only shows up
        // in tooling that runs the sources without an Info.plist.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
        let subtitleLabel = makeLabel(L(.appSubtitle, ["version": "v\(version)"]), size: 12, weight: .medium, color: .secondaryLabelColor)
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
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),

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
        let title = makeSectionTitle(L(.sectionLocalConsole))
        card.addSubview(title)

        let urlContainer = makeInsetView()
        urlContainer.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(urlContainer)

        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        urlLabel.textColor = .labelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlContainer.addSubview(urlLabel)

        copyButton.title = L(.copy)
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

        configureActionButton(openButton, title: L(.openWeb), action: #selector(didClickOpen))
        openButton.keyEquivalent = "\r"
        configureActionButton(toggleButton, title: L(.startService), action: #selector(didClickToggle))
        configureActionButton(restartButton, title: L(.restart), action: #selector(didClickRestart))

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
        portField.stringValue = "\(SettingsManager.shared.port)"
        portField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        portField.alignment = .center
        portField.delegate = self
        portField.setAccessibilityLabel(L(.serverPort))
        configureActionButton(portResetButton, title: L(.defaultButton), action: #selector(didResetPort))
        portField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let portControls = horizontalControls([portField, portResetButton])

        hotKeyButton.title = SettingsManager.shared.globalHotKeyDisplayString
        configureActionButton(hotKeyButton, title: hotKeyButton.title, action: #selector(didClickRecordHotKey))
        configureActionButton(hotKeyResetButton, title: L(.reset), action: #selector(didClickResetHotKey))
        hotKeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        updateHotKeyAppearance()
        let hotKeyControls = horizontalControls([hotKeyButton, hotKeyResetButton])

        launchAtLoginCheckbox.state = SettingsManager.shared.isLaunchAtLoginEnabled ? .on : .off
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(didToggleLaunchAtLogin)
        launchAtLoginCheckbox.setAccessibilityLabel(L(.launchAtLogin))
        autoRestartCheckbox.state = SettingsManager.shared.autoRestartEnabled ? .on : .off
        autoRestartCheckbox.target = self
        autoRestartCheckbox.action = #selector(didToggleAutoRestart)
        autoRestartCheckbox.setAccessibilityLabel(L(.automaticRecovery))

        languagePopup.removeAllItems()
        for language in AppLanguage.allCases {
            languagePopup.addItem(withTitle: language.displayName)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        if let current = AppLanguage.allCases.firstIndex(of: SettingsManager.shared.language) {
            languagePopup.selectItem(at: current)
        }
        languagePopup.target = self
        languagePopup.action = #selector(didChangeLanguage)
        languagePopup.setAccessibilityLabel(L(.language))
        languagePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 128).isActive = true

        notificationInfoLabel.font = .systemFont(ofSize: 12)
        notificationInfoLabel.textColor = .secondaryLabelColor
        configureActionButton(notificationActionButton, title: L(.notifActionSettings), action: #selector(didClickNotificationAction))
        let notificationText = makeTextStack(title: L(.notifications), description: L(.notificationsDesc))
        notificationInfoLabel.lineBreakMode = .byWordWrapping
        notificationInfoLabel.maximumNumberOfLines = 0
        notificationText.addArrangedSubview(notificationInfoLabel)
        notificationInfoLabel.widthAnchor.constraint(equalTo: notificationText.widthAnchor).isActive = true

        dshInfoLabel.font = .systemFont(ofSize: 12)
        dshInfoLabel.textColor = .secondaryLabelColor
        dshInfoLabel.lineBreakMode = .byTruncatingMiddle
        configureActionButton(dshActionButton, title: L(.recheck), action: #selector(didClickDshAction))
        let dshText = dynamicTextStack(title: L(.dshCommandLine), label: dshInfoLabel)

        tagInfoLabel.font = .systemFont(ofSize: 12)
        tagInfoLabel.textColor = .secondaryLabelColor
        let channelText = dynamicTextStack(title: L(.installChannel), label: tagInfoLabel)
        tagPopup.removeAllItems()
        tagPopup.target = self
        tagPopup.action = #selector(didChangeTag)
        tagPopup.setAccessibilityLabel(L(.installChannel))
        configureActionButton(tagInstallButton, title: L(.installEllipsis), action: #selector(didClickInstallTag))
        let channelControls = horizontalControls([tagPopup, tagInstallButton])
        tagPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tagPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tagPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let channel = NSStackView(views: [channelText, channelControls])
        channel.orientation = .vertical
        channel.alignment = .leading
        channel.spacing = 10
        channelText.widthAnchor.constraint(equalTo: channel.widthAnchor).isActive = true
        channelControls.widthAnchor.constraint(equalTo: channel.widthAnchor).isActive = true

        makeInstallTaskView()

        updateInfoLabel.font = .systemFont(ofSize: 12)
        updateInfoLabel.textColor = .secondaryLabelColor
        updateInfoLabel.stringValue = L(.updateCurrentVersion, ["version": UpdateManager.shared.currentVersion])
        let updateText = dynamicTextStack(title: L(.barUpdates), label: updateInfoLabel)
        configureActionButton(updateCheckButton, title: L(.updateCheckNow), action: #selector(didClickCheckForUpdates))
        updateCheckButton.isEnabled = UpdateManager.shared.canCheckForUpdates
        autoUpdateCheckbox.title = L(.autoCheckUpdates)
        autoUpdateCheckbox.state = UpdateManager.shared.automaticallyChecksForUpdates ? .on : .off
        autoUpdateCheckbox.target = self
        autoUpdateCheckbox.action = #selector(didToggleAutoUpdates)
        let update = NSStackView(views: [settingsRow(text: updateText, control: updateCheckButton), autoUpdateCheckbox])
        update.orientation = .vertical
        update.alignment = .leading
        update.spacing = 8
        update.arrangedSubviews[0].widthAnchor.constraint(equalTo: update.widthAnchor).isActive = true

        let service = settingsGroup(title: L(.settingsService), symbol: "server.rack", rows: [
            settingsRow(text: makeTextStack(title: L(.serverPort), description: L(.defaultPortLabel, ["port": "3080"])), control: portControls),
            settingsRow(text: makeTextStack(title: L(.automaticRecovery), description: L(.automaticRecoveryDesc)), control: autoRestartCheckbox)
        ])
        let versions = settingsGroup(title: L(.settingsVersions), symbol: "arrow.down.circle", rows: [
            settingsRow(text: dshText, control: dshActionButton), channel, installTaskStack, update
        ])
        let general = settingsGroup(title: L(.settingsGeneral), symbol: "gearshape", rows: [
            settingsRow(text: makeTextStack(title: L(.launchAtLogin), description: L(.launchAtLoginDesc)), control: launchAtLoginCheckbox),
            settingsRow(text: makeTextStack(title: L(.globalShortcut), description: L(.globalShortcutDesc)), control: hotKeyControls),
            settingsRow(text: notificationText, control: notificationActionButton),
            settingsRow(text: makeTextStack(title: L(.language), description: L(.languageDesc)), control: languagePopup)
        ])
        let groups = NSStackView(views: [service, versions, general])
        groups.orientation = .vertical
        groups.alignment = .leading
        groups.spacing = 20
        for group in groups.arrangedSubviews {
            group.widthAnchor.constraint(equalTo: groups.widthAnchor).isActive = true
        }
        return groups
    }

    private func horizontalControls(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        views.forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        return stack
    }

    private func settingsRow(text: NSView, control: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(text)
        row.addSubview(control)
        text.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            text.topAnchor.constraint(equalTo: row.topAnchor),
            text.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            text.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -20),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualTo: control.heightAnchor)
        ])
        return row
    }

    private func dynamicTextStack(title: String, label: NSTextField) -> NSStackView {
        let stack = NSStackView(views: [makeLabel(title, size: 13, weight: .medium), label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func settingsGroup(title: String, symbol: String, rows: [NSView]) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let heading = horizontalControls([icon, makeLabel(title, size: 13, weight: .semibold)])
        let card = makeCardView()
        let body = NSStackView(views: rows)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 16
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)
        for row in rows {
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            body.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        let group = NSStackView(views: [heading, card])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 8
        card.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        return group
    }

    private func makeInstallTaskView() {
        installTaskStack.arrangedSubviews.forEach {
            installTaskStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        installTaskStack.orientation = .vertical
        installTaskStack.alignment = .leading
        installTaskStack.spacing = 8
        tagInstallStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        tagInstallStatusLabel.lineBreakMode = .byWordWrapping
        tagInstallStatusLabel.maximumNumberOfLines = 0
        configureActionButton(tagCancelButton, title: L(.cancel), action: #selector(didClickCancelInstall))
        tagCancelButton.toolTip = L(.installCancelHint)
        let heading = settingsRow(text: tagInstallStatusLabel, control: tagCancelButton)
        tagInstallProgress.style = .bar
        tagInstallProgress.isIndeterminate = true
        tagInstallProgress.minValue = 0
        tagInstallProgress.maxValue = 1
        tagInstallProgress.usesThreadedAnimation = true
        tagInstallMetricsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tagInstallMetricsLabel.textColor = .secondaryLabelColor
        configureActionButton(tagDetailsButton, title: L(.installShowDetails), action: #selector(didClickInstallDetails))
        tagDetailsButton.bezelStyle = .inline
        tagDetailsButton.font = .systemFont(ofSize: 11)
        tagLogScroll.hasVerticalScroller = true
        tagLogScroll.drawsBackground = false
        tagLogScroll.borderType = .bezelBorder
        tagLogScroll.documentView = tagLogText
        tagLogText.isEditable = false
        tagLogText.isSelectable = true
        tagLogText.isRichText = false
        tagLogText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tagLogText.textColor = .labelColor
        tagLogText.backgroundColor = .textBackgroundColor
        tagLogText.textContainerInset = NSSize(width: 8, height: 8)
        tagLogText.isVerticallyResizable = true
        tagLogText.isHorizontallyResizable = false
        tagLogText.autoresizingMask = [.width]
        tagLogText.textContainer?.widthTracksTextView = true
        tagLogText.setAccessibilityLabel(L(.installShowDetails))
        for view in [heading, tagInstallProgress, tagInstallMetricsLabel, tagDetailsButton, tagLogScroll] {
            installTaskStack.addArrangedSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            if view !== tagDetailsButton {
                view.widthAnchor.constraint(equalTo: installTaskStack.widthAnchor).isActive = true
            }
        }
        tagLogScroll.heightAnchor.constraint(equalToConstant: 132).isActive = true
        tagInstallProgress.heightAnchor.constraint(equalToConstant: 5).isActive = true
        refreshInstallProgress()
    }

    private func makeFooterView() -> NSView {
        let footer = NSView()

        logsButton.title = L(.viewLiveLogs)
        logsButton.bezelStyle = .accessoryBarAction
        logsButton.target = self
        logsButton.action = #selector(didClickLogs)
        logsButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(logsButton)

        diagnosticsButton.title = L(.copyDiagnostics)
        diagnosticsButton.bezelStyle = .accessoryBarAction
        diagnosticsButton.target = self
        diagnosticsButton.action = #selector(didClickCopyDiagnostics)
        diagnosticsButton.setAccessibilityLabel(L(.copyDiagnostics))
        diagnosticsButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(diagnosticsButton)

        let closeButton = NSButton(title: L(.done), target: self, action: #selector(didClickClose))
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(closeButton)

        NSLayoutConstraint.activate([
            logsButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            logsButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            logsButton.widthAnchor.constraint(equalToConstant: 120),
            logsButton.heightAnchor.constraint(equalToConstant: 30),

            diagnosticsButton.leadingAnchor.constraint(equalTo: logsButton.trailingAnchor, constant: 10),
            diagnosticsButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            diagnosticsButton.widthAnchor.constraint(equalToConstant: 132),
            diagnosticsButton.heightAnchor.constraint(equalToConstant: 30),

            closeButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 74),
            closeButton.heightAnchor.constraint(equalToConstant: 30)
        ])

        return footer
    }

    private func makeCardView() -> NSView {
        let view = NSBox()
        view.boxType = .custom
        view.titlePosition = .noTitle
        view.cornerRadius = 10
        view.fillColor = .controlBackgroundColor
        view.borderColor = .separatorColor
        view.borderWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.5
        view.contentViewMargins = .zero
        return view
    }

    private func makeInsetView() -> NSView {
        let view = NSBox()
        view.boxType = .custom
        view.titlePosition = .noTitle
        view.cornerRadius = 6
        view.fillColor = .windowBackgroundColor
        view.borderWidth = 0
        view.contentViewMargins = .zero
        return view
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        return separator
    }

    private func makeSectionTitle(_ text: String) -> NSTextField {
        makeLabel(text, size: 12, weight: .semibold, color: .secondaryLabelColor)
    }

    private func makeTextStack(title: String, description: String) -> NSStackView {
        let titleLabel = makeLabel(title, size: 13, weight: .medium)
        let descriptionLabel = makeLabel(description, size: 12, color: .secondaryLabelColor)
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.maximumNumberOfLines = 0
        descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [titleLabel, descriptionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        descriptionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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
        updateCheckButton.isEnabled = UpdateManager.shared.canCheckForUpdates
        clearPendingTagRestart(isRunning: snapshot.isRunning)
        let color: NSColor
        switch snapshot.phase {
        case .running:
            color = .systemGreen
            statusText.stringValue = L(.runningPort, ["port": "\(snapshot.port)"])
        case .checking:
            color = .systemOrange
            statusText.stringValue = L(.statusChecking)
        case .starting:
            color = .systemOrange
            statusText.stringValue = L(.statusStarting)
        case .stopping:
            color = .systemOrange
            statusText.stringValue = L(.statusStopping)
        case .restarting:
            color = .systemOrange
            statusText.stringValue = L(.statusRestarting)
        case .portConflict:
            color = .systemRed
            statusText.stringValue = L(.statusPortInUse)
        case .error:
            color = .systemRed
            statusText.stringValue = L(.statusError)
        case .stopped:
            color = .secondaryLabelColor
            statusText.stringValue = L(.statusStoppedWord)
        }

        statusBadge.fillColor = color.withAlphaComponent(0.15)
        statusBadge.borderColor = color.withAlphaComponent(0.4)
        statusDot.fillColor = color
        statusText.textColor = color

        var details: [String] = []
        if let pid = snapshot.pid { details.append(L(.pidLabel, ["pid": "\(pid)"])) }
        if let uptime = snapshot.uptime { details.append(L(.upLabel, ["duration": Self.formatDuration(uptime)])) }
        if let version = snapshot.dshVersion { details.append(L(.dshVersionLabel, ["version": version])) }
        if let message = snapshot.message { details.append(message) }
        // An automatic restart restores the service but must not bury the fact
        // that it died: notifications may never have been delivered at all.
        if let notice = ServiceManager.shared.recoveryNotice { details.append(notice) }
        if details.isEmpty {
            details.append(snapshot.phase == .stopped ? L(.serviceNotRunning) : L(.checkingServiceStatus))
        }
        serviceDetailsLabel.stringValue = details.joined(separator: "  •  ")
        if ServiceManager.shared.recoveryNotice != nil {
            serviceDetailsLabel.textColor = .systemOrange
        } else {
            serviceDetailsLabel.textColor = .secondaryLabelColor
        }

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
            toggleButton.title = L(.stopExternal)
            restartButton.title = L(.adoptRestart)
        case .running:
            toggleButton.title = L(.stopService)
            restartButton.title = L(.restart)
        case .portConflict, .error:
            toggleButton.title = L(.retryStart)
            restartButton.title = L(.restart)
        default:
            toggleButton.title = L(.startService)
            restartButton.title = L(.restart)
        }

        if !ServiceManager.shared.dshDetectionComplete {
            dshInfoLabel.stringValue = L(.searchingPath)
            dshActionButton.title = L(.checkingEllipsis)
            dshActionButton.isEnabled = false
        } else if let path = snapshot.dshPath {
            let version = snapshot.dshVersion.map { " • \($0)" } ?? ""
            dshInfoLabel.stringValue = L(.installedAt, ["path": path, "version": version])
            dshActionButton.title = L(.recheck)
            dshActionButton.isEnabled = true
        } else {
            dshInfoLabel.stringValue = L(.notFoundInstallNpm)
            dshActionButton.title = L(.installEllipsis)
            dshActionButton.isEnabled = true
        }

        refreshTagRow()
        updateUrlDisplay(port: SettingsManager.shared.port)
    }

    /// Re-render the install-channel row from the current state.
    ///
    /// Every path that can change the row funnels through here: the probe
    /// finishing, the user picking a tag, an install ending, the service
    /// starting or stopping, the panel opening. One apply point means the row
    /// cannot show a stale version next to a fresh popup.
    private func refreshTagRow() {
        let presentation = tagRowPresentation(
            state: tagProbeState,
            installedTag: installedTagName,
            isRunning: ServiceManager.shared.isRunning,
            pendingRestart: pendingTagRestart,
            installActivity: DshVersionController.shared.installActivity,
            allowsRetry: installOutcome == .installCancelled || installOutcome == .installStopped
        )

        let options = tagProbeState.options()
        tagPopup.removeAllItems()
        for option in options {
            let title = option.isInstalled
                ? L(.tagInstalledSuffix, ["tag": option.tag, "version": option.version])
                : "\(option.tag) — \(option.version)"
            tagPopup.addItem(withTitle: title)
            tagPopup.lastItem?.representedObject = option.tag
        }
        if let preferred = SettingsManager.shared.preferredDshTag,
           let index = options.firstIndex(where: { $0.tag == preferred }) {
            tagPopup.selectItem(at: index)
        }
        tagPopup.isEnabled = presentation.popupEnabled

        tagInstallButton.title = presentation.installButtonTitle
        tagInstallButton.isEnabled = presentation.installButtonEnabled
        tagInfoLabel.stringValue = presentation.description
        tagInfoLabel.textColor = presentation.showsRestartNotice
            ? .systemOrange
            : .secondaryLabelColor
        refreshInstallProgress()
    }

    private func refreshInstallProgress() {
        let controller = DshVersionController.shared
        let activity = controller.installActivity
        let visible = activity != nil && window?.isVisible == true
        installTaskStack.isHidden = activity == nil && installOutcome == nil && controller.lastInstallLog.isEmpty
        tagInstallProgress.isHidden = activity == nil
        tagCancelButton.isHidden = activity == nil
        tagInstallMetricsLabel.isHidden = activity == nil
        if let activity {
            let presentation = installProgressPresentation(activity: activity, now: ProcessInfo.processInfo.systemUptime)
            tagInstallStatusLabel.stringValue = presentation.title
            tagInstallStatusLabel.textColor = .labelColor
            tagInstallMetricsLabel.stringValue = presentation.metrics
            tagInstallProgress.isIndeterminate = presentation.fraction == nil
            if let fraction = presentation.fraction { tagInstallProgress.doubleValue = fraction }
            tagCancelButton.isEnabled = presentation.canCancel
            tagCancelButton.title = presentation.canCancel ? L(.cancel) : L(.installCancelling)
            tagInstallProgress.setAccessibilityLabel(presentation.title)
            tagInstallMetricsLabel.setAccessibilityLabel(presentation.metrics)
        } else if let outcome = installOutcome {
            tagInstallStatusLabel.stringValue = L(outcome)
            tagInstallStatusLabel.textColor = outcome == .installStopped ? .systemRed : .secondaryLabelColor
        }
        tagDetailsButton.title = showsInstallDetails ? L(.installHideDetails) : L(.installShowDetails)
        tagDetailsButton.state = showsInstallDetails ? .on : .off
        tagLogScroll.isHidden = !showsInstallDetails
        let log = activity?.outputTail ?? controller.lastInstallLog
        let renderedLog = log.isEmpty ? L(.installLogEmpty) : log
        if tagLogText.string != renderedLog {
            let atBottom = tagLogScroll.contentView.bounds.maxY >= tagLogText.bounds.height - 24
            tagLogText.string = renderedLog
            if atBottom { tagLogText.scrollToEndOfDocument(nil) }
        }
        if visible {
            if tagInstallProgress.isIndeterminate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                tagInstallProgress.startAnimation(nil)
            } else {
                tagInstallProgress.stopAnimation(nil)
            }
            if tagInstallTimer == nil {
                let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                    self?.refreshInstallProgress()
                }
                tagInstallTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        } else {
            stopInstallProgress()
        }
    }

    @objc private func didClickCancelInstall() {
        DshVersionController.shared.cancelInstall()
        refreshInstallProgress()
    }

    @objc private func didClickInstallDetails() {
        showsInstallDetails.toggle()
        refreshInstallProgress()
    }

    @objc private func stopInstallProgress() {
        tagInstallProgress.stopAnimation(nil)
        tagInstallTimer?.invalidate()
        tagInstallTimer = nil
    }

    /// Clear the "restart to use it" notice, but only on evidence.
    ///
    /// `updateState` runs every ~2s, so the notice cannot simply be dropped when
    /// the service happens to be running when the tick arrives — that would wipe
    /// it immediately after the install that set it, and the user would never
    /// learn they had to restart. Two edges count:
    ///
    /// - the service went from not-running to running — that is the restart;
    /// - the installed version changed, which means the service re-detected dsh
    ///   and now runs the binary npm just wrote.
    ///
    /// An install performed while the service was already stopped needs no
    /// restart at all, so that one clears at once: `tagRestartFromRunning`
    /// records whether there was anything to restart in the first place.
    private func clearPendingTagRestart(isRunning: Bool) {
        defer { lastTagServiceRunning = isRunning }
        guard pendingTagRestart else { return }

        let restarted = isRunning && !lastTagServiceRunning
        let versionChanged = tagProbeState.installedVersion != nil
            && ServiceManager.shared.snapshot.dshVersion != tagProbeState.installedVersion
        if !tagRestartFromRunning || restarted || versionChanged {
            pendingTagRestart = false
        }
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
                    self?.showAlert(title: L(.couldNotStopService), message: message)
                }
            }
        } else {
            toggleButton.isEnabled = false
            ServiceManager.shared.startService { [weak self] success, message in
                self?.toggleButton.isEnabled = true
                if !success, ServiceManager.shared.snapshot.dshPath == nil {
                    DshInstallAssistant.present()
                } else if !success, let message = message {
                    self?.showAlert(title: L(.couldNotStartService), message: message)
                }
            }
        }
    }

    private func stopUnmanagedService(pid: Int32) {
        toggleButton.isEnabled = false
        ServiceManager.shared.stopUnmanagedService(pid: pid) { [weak self] success, message in
            self?.toggleButton.isEnabled = true
            if !success, let message = message {
                self?.showAlert(title: L(.couldNotStopExternal), message: message)
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
                self?.showAlert(title: L(.couldNotRestartService), message: message)
            }
        }
    }

    private func restartUnmanagedService(pid: Int32) {
        restartButton.isEnabled = false
        ServiceManager.shared.restartUnmanagedService(pid: pid) { [weak self] success, message in
            self?.restartButton.isEnabled = true
            if !success, let message = message {
                self?.showAlert(title: L(.couldNotRestartExternal), message: message)
            }
        }
    }
    
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: L(.ok))
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
            dshActionButton.title = L(.checkingEllipsis)
            ServiceManager.shared.detectDshInstallation { [weak self] _ in
                self?.dshActionButton.isEnabled = true
            }
        }
    }

    /// Record the user's chosen channel. Nothing is installed here — the
    /// Install button beside the popup is the only thing that runs npm.
    @objc private func didChangeTag() {
        guard let tag = tagPopup.selectedItem?.representedObject as? String,
              DshVersionController.validTag(tag) else { return }
        SettingsManager.shared.preferredDshTag = tag
        refreshTagRow()
    }

    /// Fetch the dist-tags and resolve which channel is on disk.
    ///
    /// Runs on every panel open, like the binary check next to it: tags move
    /// between launches and the user's dsh can be upgraded by something else
    /// entirely (nvm, brew, another terminal).
    private func loadTagOptions() {
        // A panel opened twice while a probe is in flight must not stack two
        // requests. Nothing else blocks the retry: after a failure the state is
        // `.failed`, not `.loading`, so the next open probes again.
        guard !tagProbeState.isLoading else { return }
        tagProbeState = .loading
        refreshTagRow()
        DshVersionController.shared.fetchTags { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let tags):
                let installed = ServiceManager.shared.snapshot.dshVersion
                self.tagProbeState = .loaded(tags: tags, installedVersion: installed)
                self.installedTagName = self.tagProbeState.installedTag
            case .failure(let reason):
                self.tagProbeState = .failed(reason)
                self.installedTagName = nil
            }
            self.refreshTagRow()
        }
    }

    /// Confirm, run, report. Nothing here restarts the service or rolls back on
    /// failure — see the spec's "明确不做的事".
    @objc private func didClickInstallTag() {
        guard let tag = tagPopup.selectedItem?.representedObject as? String,
              DshVersionController.validTag(tag),
              let command = DshVersionController.installCommand(forTag: tag) else { return }
        guard !DshVersionController.shared.isInstalling else { return }

        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L(.installConfirmTitle)
        // Show the requested package/channel. The dialog explains that its
        // verified archive is downloaded first, then passed to the detected npm.
        alert.informativeText = L(.installConfirmBody, ["command": command])
        alert.alertStyle = .warning
        alert.addButton(withTitle: L(.installEllipsis))
        alert.addButton(withTitle: L(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        SettingsManager.shared.preferredDshTag = tag
        installOutcome = nil
        showsInstallDetails = false
        tagInstallButton.isEnabled = false
        let wasRunning = ServiceManager.shared.isRunning
        DshVersionController.shared.install(tag: tag) { [weak self] result in
            guard let self, !DshVersionController.shared.isTerminating else { return }
            switch result {
            case .success:
                self.installOutcome = .installFinished
                // Re-probe rather than assume: npm can exit 0 having changed
                // nothing, and the honest answer is the one the binary reports.
                self.pendingTagRestart = wasRunning
                self.tagRestartFromRunning = wasRunning
                ServiceManager.shared.detectDshInstallation()
                self.loadTagOptions()
            case .failure(let error):
                if case .cancelled = error as? DshVersionControllerError {
                    self.installOutcome = .installCancelled
                } else {
                    self.installOutcome = .installStopped
                    self.showsInstallDetails = true
                    self.showAlert(title: L(.installFailedTitle), message: error.localizedDescription)
                }
                // Cancellation can interrupt npm after it has changed files.
                ServiceManager.shared.detectDshInstallation()
                self.loadTagOptions()
            }
            self.refreshTagRow()
        }
        refreshTagRow()
    }
    
    @objc private func didClickCopy() {
        ServiceManager.shared.copyURLToClipboard()
        copyButton.title = L(.copied)
        copyButton.isEnabled = false
        copyFeedbackTimer?.invalidate()
        copyFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.copyButton.title = L(.copy)
            self?.copyButton.isEnabled = true
        }
    }

    /// A hot key that failed to register is the one failure a user can act on,
    /// so the row that shows it has to look wrong — not just behave wrong.
    private func updateHotKeyAppearance() {
        let failed = HotKeyManager.shared.lastRegistrationStatus != nil
        hotKeyButton.contentTintColor = failed ? .systemRed : .labelColor
        if failed {
            hotKeyButton.toolTip = L(.hotKeyConflict, [
                "keys": SettingsManager.shared.globalHotKeyDisplayString,
                "code": HotKeyManager.shared.lastRegistrationStatus.map { "\($0)" } ?? ""
            ])
        } else {
            hotKeyButton.toolTip = nil
        }
    }

    @objc private func didClickCopyDiagnostics() {
        ServiceManager.shared.copyDiagnosticsToClipboard()
        let original = L(.copyDiagnostics)
        diagnosticsButton.title = L(.copied)
        copyFeedbackTimer?.invalidate()
        copyFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.diagnosticsButton.title = original
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
                    alert.messageText = L(.portUpdatedTitle, ["port": "\(newPort)"])
                    alert.informativeText = L(.portUpdatedBody)
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: L(.restartNow))
                    alert.addButton(withTitle: L(.later))
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
        hotKeyButton.title = L(.recording)
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

            // Refuse a combination another app already owns *before* storing
            // it. Persisting first used to leave the preference showing a
            // shortcut that could never fire, with nothing on screen to say so.
            // The conflict check is global, so our own hot key has to come off
            // first or every probe would collide with it.
            HotKeyManager.shared.unregister(id: 1)
            guard HotKeyManager.shared.isAvailable(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers) else {
                SettingsManager.shared.onHotKeyChanged?()
                self.showHotKeyConflict(display)
                self.stopRecording(cancelled: true)
                return nil
            }

            SettingsManager.shared.updateGlobalHotKey(
                keyCode: UInt32(event.keyCode),
                modifiers: carbonModifiers,
                display: display
            )

            if let status = HotKeyManager.shared.lastRegistrationStatus {
                showHotKeyConflict(display, status: status)
            }

            self.stopRecording(cancelled: false)
            return nil
        }

        // A local monitor only sees keys sent to this app, so recording
        // silently froze whenever the panel lost focus mid-recording. The
        // global monitor covers the other half; both are needed because they
        // are mutually exclusive by design.
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleRecordedKey(event)
        }
    }

    private func handleRecordedKey(_ event: NSEvent) {
        guard isRecordingHotKey else { return }
        if event.keyCode == 53 {
            stopRecording(cancelled: true)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) || flags.contains(.shift) else {
            return
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

        HotKeyManager.shared.unregister(id: 1)
        guard HotKeyManager.shared.isAvailable(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers) else {
            SettingsManager.shared.onHotKeyChanged?()
            showHotKeyConflict(display)
            stopRecording(cancelled: true)
            return
        }

        SettingsManager.shared.updateGlobalHotKey(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers,
            display: display
        )

        if let status = HotKeyManager.shared.lastRegistrationStatus {
            showHotKeyConflict(display, status: status)
        }
        stopRecording(cancelled: false)
    }

    private func showHotKeyConflict(_ display: String, status: OSStatus? = nil) {
        showAlert(
            title: L(.hotKeyConflictTitle),
            message: L(.hotKeyConflict, [
                "keys": display,
                "code": status.map { "\($0)" } ?? ""
            ])
        )
    }
    
    private func stopRecording(cancelled: Bool) {
        isRecordingHotKey = false
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
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
        updateHotKeyAppearance()
    }
    
    private static func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return L(.durationDaysHours, ["days": "\(days)", "hours": "\(hours)"]) }
        if hours > 0 { return L(.durationHoursMinutes, ["hours": "\(hours)", "minutes": "\(minutes)"]) }
        return "\(minutes)m"
    }

    // MARK: - Preferences Actions
    @objc private func didChangeLanguage() {
        guard let raw = languagePopup.selectedItem?.representedObject as? String,
              let language = AppLanguage(rawValue: raw) else { return }
        SettingsManager.shared.language = language
    }

    /// Rebuilds the panel in the new language.
    ///
    /// Every string here is resolved at construction time, so re-running the
    /// builder is what makes the switch complete — re-setting a hand-picked list
    /// of controls would quietly miss whichever one gets added next. The work is
    /// deferred because this runs from inside the popup's own action.
    private func rebuildForLanguage() {
        let effective = Localization.shared.effective
        guard effective != lastEffectiveLanguage else { return }
        lastEffectiveLanguage = effective
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let wasVisible = window.isVisible
            self.setupUI()
            self.updateState(ServiceManager.shared.snapshot)
            self.updateNotificationRow()
            self.launchAtLoginCheckbox.state = SettingsManager.shared.isLaunchAtLoginEnabled ? .on : .off
            self.autoRestartCheckbox.state = SettingsManager.shared.autoRestartEnabled ? .on : .off
            self.portField.stringValue = "\(SettingsManager.shared.port)"
            // `setupUI()` above rebuilt the popup with no items. `loadTagOptions`
            // sets `.loading` and refreshes on its own; the explicit refresh after
            // it covers the case where a probe was already in flight and the
            // guard returned, leaving the freshly built views unfilled.
            self.loadTagOptions()
            self.refreshTagRow()
            if wasVisible {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    @objc private func didToggleLaunchAtLogin() {
        let enabled = (launchAtLoginCheckbox.state == .on)
        SettingsManager.shared.isLaunchAtLoginEnabled = enabled
    }

    @objc private func didToggleAutoRestart() {
        let enabled = (autoRestartCheckbox.state == .on)
        ServiceManager.shared.autoRestartEnabled = enabled
        if !enabled {
            ServiceManager.shared.cancelPendingAutoRestart()
        }
    }

    @objc private func didClickCheckForUpdates() {
        UpdateManager.shared.checkForUpdates(self)
    }

    /// The single write of Sparkle's auto-check flag, from the user's own
    /// toggle. Never written on load: reasserting the value at startup would
    /// paper over (and destroy evidence of) whatever the user last chose.
    @objc private func didToggleAutoUpdates() {
        UpdateManager.shared.automaticallyChecksForUpdates =
            (autoUpdateCheckbox.state == .on)
    }

    @objc private func didClickNotificationAction() {
        ServiceNotifier.shared.requestAuthorizationIfNeeded {
            ServiceNotifier.shared.refreshAvailability()
        }
        ServiceNotifier.shared.openSystemNotificationSettings()
    }

    /// Keeps the recovery row honest. A notification that silently never arrives
    /// is the worst failure mode for this feature, so the panel states the
    /// condition instead of implying everything is fine.
    private func updateNotificationRow() {
        let notifier = ServiceNotifier.shared
        notificationInfoLabel.stringValue = notifier.availability.shortDescription
        switch notifier.availability {
        case .available:
            notificationInfoLabel.textColor = .secondaryLabelColor
            notificationActionButton.title = L(.notifActionSettings)
        case .unknown:
            notificationInfoLabel.textColor = .secondaryLabelColor
            notificationActionButton.title = L(.notifActionEnable)
        case .denied, .unusable:
            notificationInfoLabel.textColor = .systemOrange
            notificationActionButton.title = L(.notifActionFix)
        }
    }
    
    @objc private func didClickClose() {
        stopInstallProgress()
        if isRecordingHotKey {
            stopRecording(cancelled: true)
        }
        self.window?.orderOut(nil)
    }
}
