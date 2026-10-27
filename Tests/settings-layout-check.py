#!/usr/bin/env python3
"""Render the real dashboard offscreen with inert services/settings/updater.

No application entry point, real settings, service process, network or display
capture is used. Swift build products/cache are temporary; PNGs remain under
build/settings-preview for inspection.
"""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("dashboard_fixture", ROOT / "Tests/dashboard-ui-fixture.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)

checks = r'''
_ = NSApplication.shared
NSApplication.shared.applicationIconImage = NSImage(contentsOfFile: CommandLine.arguments[2])
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let panel = DashboardWindowController()
let window = panel.window!
window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
let model = DshVersionController.shared
var requestedWidth: CGFloat = 540
func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants($0) }
}
func layout() {
    pump(0.05)
    for _ in 0..<3 {
        window.contentView!.updateConstraintsForSubtreeIfNeeded()
        window.contentView!.layoutSubtreeIfNeeded()
    }
}
func document() -> NSView {
    (window.contentView!.subviews.first { $0 is NSScrollView } as! NSScrollView).documentView!
}
func capture(_ view: NSView, _ name: String) {
    let bounds = view.bounds
    expect(bounds.width > 0 && bounds.height > 0, "empty capture \(name)")
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(ceil(bounds.width * 2)), pixelsHigh: Int(ceil(bounds.height * 2)),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("no bitmap for \(name)") }
    bitmap.size = bounds.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    window.effectiveAppearance.performAsCurrentDrawingAppearance {
        // Hidden visual-effect views have no WindowServer material backing.
        // Paint the semantic fallback in pixels before caching the real views.
        context.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
    }
    NSGraphicsContext.restoreGraphicsState()
    window.effectiveAppearance.performAsCurrentDrawingAppearance {
        view.cacheDisplay(in: bounds, to: bitmap)
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encode") }
    expect(png.count > 4000, "blank/tiny PNG: \(name)")
    try! png.write(to: output.appendingPathComponent(name + ".png"))
}
func geometry(_ name: String, active: Bool) {
    layout()
    let doc = document()
    expect(abs(window.contentView!.bounds.width - requestedWidth) < 1,
           "window expanded beyond requested width: \(name), requested=\(requestedWidth), actual=\(window.contentView!.bounds.width)")
    if active, let container = panel.tagLogText.textContainer {
        panel.tagLogText.layoutManager?.ensureLayout(for: container)
        let used = panel.tagLogText.layoutManager!.usedRect(for: container)
        expect(used.height >= 40 && panel.tagLogText.string.contains("中文安装日志"), "actual multiline log not laid out: \(name)")
    }
    let scroll = window.contentView!.subviews.first { $0 is NSScrollView } as! NSScrollView
    expect(abs(doc.bounds.width - scroll.contentView.bounds.width) < 2, "document width drift: \(name), document=\(doc.bounds), clip=\(scroll.contentView.bounds)")
    expect(doc.bounds.height > 800, "settings document collapsed: \(name), height=\(doc.bounds.height)")
    expect(panel.tagPopup.bounds.width >= 160, "channel popup title area collapsed: \(name), width=\(panel.tagPopup.bounds.width)")
    expect(panel.tagPopup.selectedItem?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           "available channel selection has no visible title: \(name)")
    let controls: [(String, NSView)] = [
        ("port", panel.portField), ("port reset", panel.portResetButton),
        ("launch at login", panel.launchAtLoginCheckbox), ("hotkey", panel.hotKeyButton),
        ("hotkey reset", panel.hotKeyResetButton), ("DSH action", panel.dshActionButton),
        ("channel popup", panel.tagPopup), ("install", panel.tagInstallButton),
        ("update check", panel.updateCheckButton), ("auto update", panel.autoUpdateCheckbox),
        ("recovery", panel.autoRestartCheckbox), ("notification action", panel.notificationActionButton),
        ("language", panel.languagePopup)
    ] + (active ? [("cancel", panel.tagCancelButton), ("progress", panel.tagInstallProgress),
                   ("metrics", panel.tagInstallMetricsLabel), ("log disclosure", panel.tagDetailsButton),
                   ("log", panel.tagLogScroll)] : [])
    for (label, control) in controls {
        expect(control.isDescendant(of: doc), "control absent from actual dashboard: \(label)")
        expect(!control.isHiddenOrHasHiddenAncestor, "control hidden: \(label), \(name)")
        let rect = control.convert(control.bounds, to: doc)
        expect(rect.width >= 4 && rect.height >= 4, "zero-size control: \(label), \(name), \(rect)")
        expect(rect.minX >= -1 && rect.maxX <= doc.bounds.width + 1 && rect.minY >= -1 && rect.maxY <= doc.bounds.height + 1,
               "control outside document: \(label), \(name), \(rect), document=\(doc.bounds)")
    }
    let labels = descendants(doc).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor }
    for label in labels where !label.stringValue.isEmpty {
        let rect = label.convert(label.bounds, to: doc)
        expect(rect.width > 1 && rect.height > 1, "zero-size label '\(label.stringValue)' in \(name)")
        expect(rect.minX >= -1 && rect.maxX <= doc.bounds.width + 1, "label outside width '\(label.stringValue)' in \(name)")
        if label.maximumNumberOfLines == 0 && label.lineBreakMode == .byWordWrapping {
            let height = (label.stringValue as NSString).boundingRect(
                with: NSSize(width: max(1, label.bounds.width), height: 10000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: label.font ?? NSFont.systemFont(ofSize: 12)]).height
            expect(label.bounds.height + 3 >= height, "clipped wrapping label '\(label.stringValue)' in \(name): height \(label.bounds.height), needs \(height)")
        }
    }
    for key: Localization.Key in [.settingsService, .settingsVersions, .settingsGeneral,
                                  .serverPort, .automaticRecovery, .dshCommandLine, .installChannel,
                                  .barUpdates, .launchAtLogin, .globalShortcut, .notifications, .language] {
        expect(labels.contains { $0.stringValue == L(key) }, "missing grouped setting title \(key): \(name)")
    }
    // Settings rows must keep their control column separate from wrapping text.
    for label in labels where label.stringValue == L(.globalShortcut) || label.stringValue == L(.language) {
        let button = label.stringValue == L(.globalShortcut) ? panel.hotKeyButton as NSView : panel.languagePopup as NSView
        let titleRect = label.convert(label.bounds, to: doc)
        let buttonRect = button.convert(button.bounds, to: doc)
        expect(titleRect.maxX + 8 <= buttonRect.minX, "setting title overlaps control: \(name)")
    }
    let groups = descendants(doc).compactMap { $0 as? NSTextField }.filter {
        [L(.settingsService), L(.settingsVersions), L(.settingsGeneral)].contains($0.stringValue)
    }.map { $0.convert($0.bounds, to: doc).midY }
    expect(groups.count == 3 && groups[0] > groups[1] && groups[1] > groups[2], "group ordering/rows collapsed: \(name)")
    print("geometry \(name): \(Int(doc.bounds.width))×\(Int(doc.bounds.height)), \(controls.count) controls")
}
for language: AppLanguage in [.english, .chinese] {
    SettingsManager.shared.language = language
    Localization.shared.apply(language: language)
    pump(0.1)
    for (style, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        window.appearance = NSAppearance(named: appearance)
        for width in [540, 580] {
            let stem = "\(language.rawValue)-\(style)-\(width)"
            requestedWidth = CGFloat(width)
            window.setContentSize(NSSize(width: width, height: width == 540 ? 540 : 800))
            model.installActivity = nil
            model.lastInstallLog = ""
            panel.installOutcome = nil
            panel.showsInstallDetails = false
            panel.setupUI()
            panel.updateState(ServiceManager.shared.snapshot)
            panel.updateNotificationRow()
            panel.loadTagOptions()
            geometry(stem + "-idle", active: false)
            capture(document(), stem + "-idle-document")
            model.installActivity = InstallActivity(tag: "next", startedAt: ProcessInfo.processInfo.systemUptime - 65,
                phase: .downloading, bytesReceived: 1_000_000, totalBytes: 4_000_000,
                bytesPerSecond: 500_000, outputTail: "Resolving next → 2.0.0\nVerified SHA-512\nInstalling dependencies…\n中文安装日志", version: "2.0.0")
            panel.showsInstallDetails = true
            panel.refreshTagRow()
            geometry(stem + "-download", active: true)
            expect(!panel.tagInstallProgress.isIndeterminate && panel.tagInstallProgress.doubleValue == 0.25, "actual progress bar did not render snapshot")
            capture(document(), stem + "-download-document")
            capture(window.contentView!, stem + "-compact-window")
            model.installActivity?.totalBytes = nil
            panel.refreshInstallProgress()
            geometry(stem + "-unknown", active: true)
            expect(panel.tagInstallProgress.isIndeterminate && !panel.tagInstallMetricsLabel.stringValue.contains("%"), "unknown download UI fabricated percent")
            model.installActivity?.phase = .installing
            panel.refreshInstallProgress()
            geometry(stem + "-dependencies", active: true)
            expect(!panel.tagInstallMetricsLabel.stringValue.contains("/s"), "dependency UI shows archive rate")
            model.installActivity?.phase = .cancelling
            panel.refreshInstallProgress()
            geometry(stem + "-cancelling", active: true)
            expect(!panel.tagCancelButton.isEnabled, "actual cancel button remains enabled")
            panel.stopInstallProgress()
        }
    }
}
// Exercise the real notification-driven rebuild, with the same task snapshot.
let beforeLanguage = model.installActivity
Localization.shared.apply(language: .english)
pump(0.1)
expect(model.installActivity == beforeLanguage, "language rebuild reset install snapshot")
geometry("language-rebuild", active: true)
expect(panel.tagInstallStatusLabel.stringValue.contains("Cancelling"), "language rebuild retained old task text")
expect(!window.isVisible, "fixture made dashboard visible")
print("PASS settings layout: actual complete dashboard, 540/580 widths, English/Chinese, light/dark, idle/download/unknown/install/cancel, language rebuild; 24 PNGs at \(output.path)")
'''

fixture.compile_run(checks, full_dashboard=True,
                    arguments=[ROOT / "build/settings-preview", ROOT / "Resources/icon.png"])
