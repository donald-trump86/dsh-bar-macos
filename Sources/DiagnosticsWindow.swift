import Cocoa

final class DiagnosticsWindowController: NSWindowController {
    static let shared = DiagnosticsWindowController()

    private let heading = NSTextField(labelWithString: "")
    private let introduction = NSTextField(wrappingLabelWithString: "")
    private let reportView = NSTextView()
    private let recheckButton = NSButton()
    private let copyButton = NSButton()
    private let logsButton = NSButton()
    private let permissionsButton = NSButton()
    private var statusObserver: UUID?
    private var languageObserver: UUID?
    private var copyTimer: Timer?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 620, height: 440)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        setupUI()
        window.center()
        statusObserver = ServiceManager.shared.addStatusObserver { [weak self] _ in self?.refresh() }
        languageObserver = Localization.shared.addObserver { [weak self] in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let statusObserver { ServiceManager.shared.removeStatusObserver(statusObserver) }
        if let languageObserver { Localization.shared.removeObserver(languageObserver) }
        copyTimer?.invalidate()
    }

    func showDiagnostics() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        recheck()
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        introduction.font = .systemFont(ofSize: 12)
        introduction.textColor = .secondaryLabelColor
        introduction.setContentCompressionResistancePriority(.required, for: .vertical)
        heading.translatesAutoresizingMaskIntoConstraints = false
        introduction.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        reportView.isEditable = false
        reportView.isSelectable = true
        reportView.isRichText = false
        reportView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        reportView.textColor = .labelColor
        reportView.backgroundColor = .textBackgroundColor
        reportView.textContainerInset = NSSize(width: 12, height: 12)
        reportView.isVerticallyResizable = true
        reportView.isHorizontallyResizable = false
        reportView.autoresizingMask = [.width]
        reportView.textContainer?.widthTracksTextView = true
        scroll.documentView = reportView

        let buttons = NSStackView(views: [recheckButton, copyButton, logsButton, permissionsButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        for (button, action) in [(recheckButton, #selector(recheck)), (copyButton, #selector(copyReport)),
                                 (logsButton, #selector(showLogs)), (permissionsButton, #selector(showPermissions))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        for view in [heading, introduction, scroll, buttons] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            introduction.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            introduction.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            introduction.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: introduction.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: introduction.bottomAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),
            buttons.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }

    private func refresh() {
        let manager = ServiceManager.shared
        window?.title = L(.diagnosticsTitle)
        heading.stringValue = L(.diagnosticsTitle)
        introduction.stringValue = L(.diagnosticsIntroduction)
        recheckButton.title = manager.dshDetectionComplete ? L(.recheck) : L(.checkingEllipsis)
        recheckButton.isEnabled = manager.dshDetectionComplete
        copyButton.title = L(.copyDiagnostics)
        copyButton.isEnabled = manager.dshDetectionComplete
        logsButton.title = L(.viewLiveLogs)
        permissionsButton.title = L(.permissionsOpenGuide)
        let findings = manager.dshDetectionComplete
            ? manager.environmentDiagnostics?.findings(for: manager.snapshot) ?? [L(.diagnosticsNotChecked)]
            : [L(.diagnosticsChecking)]
        reportView.string = findings.map { "• \($0)" }.joined(separator: "\n\n")
            + "\n\n" + L(.diagnosticsPathAdvice) + "\n\n" + manager.diagnosticsSummary
    }

    @objc private func recheck() {
        ServiceManager.shared.detectDshInstallation()
        ServiceManager.shared.checkStatus()
    }

    @objc private func copyReport() {
        ServiceManager.shared.copyDiagnosticsToClipboard()
        copyButton.title = L(.copied)
        copyTimer?.invalidate()
        copyTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.copyButton.title = L(.copyDiagnostics)
        }
    }

    @objc private func showLogs() { LogWindowController.shared.showWindow(nil) }
    @objc private func showPermissions() { PermissionsWindowController.shared.showGuide() }
}
