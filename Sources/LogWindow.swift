import Cocoa

final class LogWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    static let shared = LogWindowController()

    private let textView = NSTextView()
    private let searchField = NSSearchField()
    private let pauseButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "Waiting for logs…")
    private var refreshTimer: Timer?
    private var readOffset: UInt64 = 0
    private var rawText = ""
    private var isPaused = false
    private var readInFlight = false
    private var fillGeneration = 0
    private let ioQueue = DispatchQueue(label: "ai.deepseek.dsh-bar.log-reader", qos: .utility)
    private let maximumBufferedCharacters = 1_000_000

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "DSH Live Logs"
        window.minSize = NSSize(width: 600, height: 360)

        super.init(window: window)
        window.delegate = self
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApplication.shared.activate(ignoringOtherApps: true)
        startFollowing()
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func setupUI() {
        guard let window, let contentView = window.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let titleLabel = NSTextField(labelWithString: "Live Service Logs")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        searchField.placeholderString = "Filter logs"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(searchField)

        pauseButton.title = "Pause"
        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pauseButton)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)

        let clearButton = NSButton(title: "Clear View", target: self, action: #selector(clearView))
        clearButton.bezelStyle = .rounded
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(clearButton)

        let revealButton = NSButton(title: "Reveal File", target: self, action: #selector(revealLogFile))
        revealButton.bezelStyle = .rounded
        revealButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(revealButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),

            pauseButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            pauseButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            pauseButton.widthAnchor.constraint(equalToConstant: 76),

            searchField.trailingAnchor.constraint(equalTo: pauseButton.leadingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 220),
            searchField.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),

            statusLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -12),

            revealButton.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            revealButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            revealButton.widthAnchor.constraint(equalToConstant: 92),

            clearButton.trailingAnchor.constraint(equalTo: revealButton.leadingAnchor, constant: -8),
            clearButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 92)
        ])
    }

    private func startFollowing() {
        refreshTimer?.invalidate()
        refreshNow()
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshNow() {
        guard !isPaused, !readInFlight else { return }
        readInFlight = true
        let url = ServiceManager.shared.logFileURL
        let offset = readOffset
        let generation = fillGeneration

        ioQueue.async { [weak self] in
            guard let self else { return }
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: url.path),
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let number = attributes[.size] as? NSNumber else {
                DispatchQueue.main.async {
                    self.readInFlight = false
                    self.statusLabel.stringValue = "No log file yet — it will appear after the service starts."
                }
                return
            }

            let size = number.uint64Value
            let initialTailSize: UInt64 = 512 * 1_024
            let effectiveOffset: UInt64
            if size < offset {
                // File was truncated or rotated: start over from the new tail.
                effectiveOffset = size > initialTailSize ? size - initialTailSize : 0
            } else if offset == 0, size > initialTailSize {
                effectiveOffset = size - initialTailSize
            } else {
                effectiveOffset = offset
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                DispatchQueue.main.async {
                    self.readInFlight = false
                    self.statusLabel.stringValue = "Could not read \(url.path)"
                }
                return
            }
            handle.seek(toFileOffset: effectiveOffset)
            let data = handle.readDataToEndOfFile()
            handle.closeFile()
            let nextOffset = effectiveOffset + UInt64(data.count)
            let chunk = String(decoding: data, as: UTF8.self)

            DispatchQueue.main.async {
                self.readInFlight = false
                // A Clear (or a truncation reset) while this read was in flight
                // supersedes it; dropping the chunk avoids resurrecting old text.
                guard generation == self.fillGeneration else { return }
                self.readOffset = nextOffset
                if !chunk.isEmpty {
                    self.rawText.append(chunk)
                    if self.rawText.count > self.maximumBufferedCharacters {
                        self.rawText = String(self.rawText.suffix(self.maximumBufferedCharacters))
                    }
                    self.renderText(scrollToBottom: true)
                }
                self.statusLabel.stringValue = "\(url.path)  •  \(Self.formatBytes(size))"
            }
        }
    }

    private func renderText(scrollToBottom: Bool) {
        // Process tokens live in the log text; redact before display so the
        // window (and anything copied from it) never leaks credentials.
        let visible = ServiceManager.redactingProcessTokens(in: rawText)
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            textView.string = visible
        } else {
            textView.string = visible
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.localizedCaseInsensitiveContains(query) }
                .joined(separator: "\n")
        }
        if scrollToBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        renderText(scrollToBottom: false)
    }

    @objc private func togglePause() {
        isPaused.toggle()
        pauseButton.title = isPaused ? "Resume" : "Pause"
        if isPaused {
            statusLabel.stringValue = "Paused"
        } else {
            refreshNow()
        }
    }

    @objc private func clearView() {
        fillGeneration += 1
        rawText = ""
        if let attributes = try? FileManager.default.attributesOfItem(
            atPath: ServiceManager.shared.logFileURL.path
        ), let number = attributes[.size] as? NSNumber {
            readOffset = number.uint64Value
        } else {
            readOffset = 0
        }
        renderText(scrollToBottom: false)
        statusLabel.stringValue = "View cleared — the log file was not deleted."
    }

    @objc private func revealLogFile() {
        ServiceManager.shared.revealLogFile()
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
