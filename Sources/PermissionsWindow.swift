import Cocoa

enum PermissionSettingsTarget: CaseIterable {
    case fullDiskAccess, automation, photos, mediaLibrary

    var settingsURL: URL {
        let pane: String
        switch self {
        case .fullDiskAccess: pane = "Privacy_AllFiles"
        case .automation: pane = "Privacy_Automation"
        case .photos: pane = "Privacy_Photos"
        case .mediaLibrary: pane = "Privacy_Media"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    var title: String {
        switch self {
        case .fullDiskAccess: return L(.permissionsFullDisk)
        case .automation: return L(.permissionsAutomation)
        case .photos: return L(.permissionsPhotos)
        case .mediaLibrary: return L(.permissionsMedia)
        }
    }

    var explanation: String {
        switch self {
        case .fullDiskAccess: return L(.permissionsFullDiskBody)
        case .automation: return L(.permissionsAutomationBody)
        case .photos: return L(.permissionsPhotosBody)
        case .mediaLibrary: return L(.permissionsMediaBody)
        }
    }

    var manualPath: String {
        L(.permissionsManualPath, ["pane": self == .photos ? L(.permissionsPhotosPane) : title])
    }
}

final class PermissionsWindowController: NSWindowController {
    static let shared = PermissionsWindowController()
    static let guideVersion = 1

    private var languageObserverToken: UUID?
    private var errorLabel: NSTextField?
    private var settingsOpenFailed = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = NSSize(width: 520, height: 460)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        setupUI()
        languageObserverToken = Localization.shared.addObserver { [weak self] in
            self?.setupUI()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let token = languageObserverToken {
            Localization.shared.removeObserver(token)
        }
    }

    func showGuide() {
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    static func openSettings(for target: PermissionSettingsTarget, openURL: (URL) -> Bool) -> Bool {
        if openURL(target.settingsURL) { return true }
        return openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
    }

    private func setupUI() {
        guard let window = window else { return }
        window.title = L(.permissionsTitle)
        let content = NSView()
        window.contentView = content

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        content.addSubview(scroll)

        let later = button(L(.permissionsLater), action: #selector(closeGuide))
        content.addSubview(later)
        NSLayoutConstraint.activate([
            later.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            later.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: later.topAnchor, constant: -16)
        ])

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])

        add(label(L(.permissionsTitle), font: .boldSystemFont(ofSize: 20)), to: stack)
        add(label(L(.permissionsIntro)), to: stack)
        for (index, target) in PermissionSettingsTarget.allCases.enumerated() {
            let section = NSStackView()
            section.orientation = .vertical
            section.alignment = .leading
            section.spacing = 8
            add(label(target.title, font: .boldSystemFont(ofSize: 14)), to: section)
            add(label(target.explanation, color: .secondaryLabelColor), to: section)
            add(label(target.manualPath, font: .systemFont(ofSize: 12), color: .secondaryLabelColor), to: section)
            let actions = NSStackView()
            actions.spacing = 8
            let open = button(L(.permissionsOpenSettings), action: #selector(openPermissionSettings(_:)))
            open.tag = index
            actions.addArrangedSubview(open)
            if target == .fullDiskAccess {
                actions.addArrangedSubview(button(L(.permissionsRevealApp), action: #selector(revealApp)))
            }
            section.addArrangedSubview(actions)
            add(section, to: stack)
        }
        add(label(L(.permissionsNote), color: .secondaryLabelColor), to: stack)
        let error = label(L(.permissionsOpenFailed), color: .systemRed)
        error.isHidden = !settingsOpenFailed
        add(error, to: stack)
        errorLabel = error
        updateSettingsError()
    }

    private func updateSettingsError() {
        errorLabel?.isHidden = !settingsOpenFailed
        if settingsOpenFailed, let error = errorLabel {
            window?.contentView?.layoutSubtreeIfNeeded()
            error.scrollToVisible(error.bounds)
        }
    }

    private func add(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func label(_ text: String, font: NSFont = .systemFont(ofSize: 13),
                       color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.textColor = color
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        return button
    }

    @objc private func openPermissionSettings(_ sender: NSButton) {
        let target = PermissionSettingsTarget.allCases[sender.tag]
        settingsOpenFailed = !Self.openSettings(for: target) { NSWorkspace.shared.open($0) }
        updateSettingsError()
    }

    @objc private func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc private func closeGuide() {
        close()
    }
}
