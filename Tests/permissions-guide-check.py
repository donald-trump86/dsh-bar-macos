#!/usr/bin/env python3
"""Compile production permissions behavior with inert AppKit fixture dependencies."""
import importlib.util
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("dashboard_fixture", ROOT / "Tests/dashboard-ui-fixture.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def settings_version_fixture():
    settings = (ROOT / "Sources/SettingsManager.swift").read_text()
    version = fixture.extract(settings, r"^    var permissionsGuideVersion: Int \{\n.*?^    \}")
    assert version.count("UserDefaults.standard") == 2, "version property defaults boundary changed"
    version = version.replace("UserDefaults.standard", "GuideDefaults.store")
    return "import Cocoa\nenum GuideDefaults { static var store: UserDefaults! }\nextension SettingsManager {\n" + version + "\n}\n"


def test_first_display_version_and_termination():
    delegate = (ROOT / "Sources/AppDelegate.swift").read_text()
    quitting = fixture.extract(delegate, r"^    private var terminationReplyPending[^\n]+")
    method = fixture.extract(delegate, r"^    private func showPermissionsGuideIfNeeded\(\) \{\n.*?^    \}")
    boundary = "PermissionsWindowController.shared.showGuide()"
    assert method.count(boundary) == 1, "first-display presentation boundary changed"
    method = method.replace(boundary, "FirstDisplayGuide.shared.showGuide()")
    harness = settings_version_fixture() + r'''
@MainActor
final class AppDelegate {
''' + quitting.replace("private ", "") + "\n" + method.replace("private ", "") + r'''
}
final class FirstDisplayGuide {
    static let shared = FirstDisplayGuide()
    var versionsAtShow: [Int] = []
    func showGuide() {
        expect(Thread.isMainThread, "presentation runs on main thread")
        versionsAtShow.append(SettingsManager.shared.permissionsGuideVersion)
    }
}
'''
    fixture.compile_run(r'''
MainActor.assumeIsolated {
expect(Thread.isMainThread, "first-display check runs on main thread")
let cases: [(stored: Int, quitting: Bool, shows: Int, saved: Int)] = [
    (0, false, 1, 1),
    (1, false, 0, 1),
    (2, false, 0, 2),
    (0, true, 0, 0)
]
for item in cases {
    let suite = "dsh-permissions-first-display-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    GuideDefaults.store = defaults
    expect(defaults.object(forKey: "DSH_PermissionsGuideVersion") == nil, "unique empty defaults suite")
    expect(SettingsManager.shared.permissionsGuideVersion == 0, "unset version defaults to zero")
    if item.stored != 0 { defaults.set(item.stored, forKey: "DSH_PermissionsGuideVersion") }
    FirstDisplayGuide.shared.versionsAtShow = []
    let delegate = AppDelegate()
    delegate.terminationReplyPending = item.quitting
    delegate.showPermissionsGuideIfNeeded()
    expect(FirstDisplayGuide.shared.versionsAtShow.count == item.shows, "show count: \(item)")
    expect(SettingsManager.shared.permissionsGuideVersion == item.saved, "final version: \(item)")
    expect(UserDefaults(suiteName: suite)!.integer(forKey: "DSH_PermissionsGuideVersion") == item.saved, "persisted exact key: \(item)")
    if item.shows == 1 {
        expect(FirstDisplayGuide.shared.versionsAtShow == [item.stored], "display before saving version")
        delegate.showPermissionsGuideIfNeeded()
        expect(FirstDisplayGuide.shared.versionsAtShow.count == 1, "initial case repeated still shows once")
        expect(SettingsManager.shared.permissionsGuideVersion == 1, "repeat preserves saved version")
    }
    print("PASS test_first_display_version_and_termination: \(item)")
}
}
''', dashboard=harness)
    startup = fixture.extract(delegate, r"^    func applicationDidFinishLaunching\(_ notification: Notification\) \{\n.*?^    \}")
    assert startup.count("showPermissionsGuideIfNeeded()") == 1, "startup schedules one first-display check"
    assert re.search(r"ServiceManager\.shared\.startMonitoring\(\)\s+DispatchQueue\.main\.async \{ \[weak self\] in\s+self\?\.showPermissionsGuideIfNeeded\(\)\s+\}\s+\}$", startup), "first-display check must be asynchronous after existing initialization"
    print("PASS test_first_display_startup_hook: one main-queue startup-tail call; app entry point excluded")


def test_manual_settings_entry():
    dashboard = (ROOT / "Sources/DashboardWindow.swift").read_text().replace("private ", "")
    fixture.compile_run(r'''
_ = NSApplication.shared
func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants($0) }
}
for stored in [0, 1, 2] {
    let suite = "dsh-permissions-manual-entry-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    GuideDefaults.store = defaults
    expect(defaults.object(forKey: "DSH_PermissionsGuideVersion") == nil, "unique empty manual-entry suite")
    if stored != 0 { defaults.set(stored, forKey: "DSH_PermissionsGuideVersion") }
    let rawBefore = defaults.object(forKey: "DSH_PermissionsGuideVersion") as? Int
    SettingsManager.shared.language = .english
    Localization.shared.apply(language: .english)
    let panel = DashboardWindowController()
    panel.window!.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    func unchanged(_ stage: String) {
        expect(SettingsManager.shared.permissionsGuideVersion == stored, "manual version at \(stage), stored=\(stored)")
        expect(defaults.object(forKey: "DSH_PermissionsGuideVersion") as? Int == rawBefore, "manual entry never writes version at \(stage)")
        let service = ServiceManager.shared
        expect(service.startCalls == 0 && service.stopCalls == 0 && service.restartCalls == 0, "zero service lifecycle calls at \(stage)")
        expect(DshVersionController.shared.installCalls == 0 && DshInstallAssistant.presentCalls == 0, "zero install calls at \(stage)")
        expect(PermissionsFixture.openedURLs.isEmpty && PermissionsFixture.revealedURLs.isEmpty, "zero Settings/Finder calls at \(stage)")
        expect(!panel.window!.isVisible, "dashboard fixture stays offscreen at \(stage)")
    }
    expect(panel.permissionsGuideButton.title == "Open Guide", "English settings button")
    expect(panel.permissionsGuideButton.target as? DashboardWindowController === panel, "real dashboard button target")
    expect(panel.permissionsGuideButton.action == #selector(DashboardWindowController.didClickPermissionsGuide), "real dashboard button action")
    let before = PermissionsFixture.shownWindows.count
    panel.permissionsGuideButton.performClick(nil)
    let guide = PermissionsWindowController.shared
    let window = guide.window!
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    expect(PermissionsFixture.shownWindows.count == before + 1, "button opens guide")
    expect(window.title == "Permissions & Access", "English guide title")
    unchanged("first manual open")
    window.performClose(nil)
    panel.permissionsGuideButton.performClick(nil)
    expect(guide.window === window && PermissionsFixture.shownWindows.count == before + 2, "button reopens same guide after close")
    unchanged("reopening")
    window.performClose(nil)
    SettingsManager.shared.language = .chinese
    Localization.shared.apply(language: .chinese)
    pump(0.15)
    expect(panel.permissionsGuideButton.title == "打开引导", "rebuilt Chinese settings button")
    let dashboardTexts = descendants(panel.window!.contentView!).compactMap { $0 as? NSTextField }.map(\.stringValue)
    expect(dashboardTexts.contains("权限与访问") && dashboardTexts.contains(L(.permissionsAccessDesc)), "rebuilt Chinese settings row")
    panel.permissionsGuideButton.performClick(nil)
    expect(guide.window === window && PermissionsFixture.shownWindows.count == before + 3, "same guide after language change")
    expect(window.title == "权限与访问", "reopened guide uses Chinese title")
    expect(descendants(window.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == L(.permissionsIntro) }, "reopened guide uses Chinese copy")
    unchanged("language change and reopen")
    window.performClose(nil)
    panel.window!.performClose(nil)
    print("PASS test_manual_settings_entry: stored=\(stored), real button, shared reopen, language rebuild, unchanged version, zero lifecycle/install/Settings/Finder calls")
}
''', dashboard=dashboard + settings_version_fixture())


def test_settings_links_and_fallback():
    fixture.compile_run(r'''
let targets: [(PermissionSettingsTarget, String)] = [
    (.fullDiskAccess, "Privacy_AllFiles"),
    (.automation, "Privacy_Automation"),
    (.photos, "Privacy_Photos"),
    (.mediaLibrary, "Privacy_Media"),
    (.localNetwork, "Privacy_LocalNetwork")
]
expect(PermissionSettingsTarget.allCases.count == targets.count, "five settings targets")
expect(PermissionSettingsTarget.allCases.last == .localNetwork, "Local Network is the fifth target")
for (target, pane) in targets {
    let expected = ["x-apple.systempreferences:com.apple.preference.security?" + pane,
                    "x-apple.systempreferences:com.apple.preference.security"]
    var attempted: [String] = []
    let direct = PermissionsWindowController.openSettings(for: target) { url in
        attempted.append(url.absoluteString)
        return true
    }
    expect(direct && attempted == [expected[0]], "first success stops: \(pane)")
    attempted = []
    let fallback = PermissionsWindowController.openSettings(for: target) { url in
        attempted.append(url.absoluteString)
        return attempted.count == 2
    }
    expect(fallback && attempted == expected, "settings fallback: \(pane)")
    attempted = []
    let failed = PermissionsWindowController.openSettings(for: target) { url in
        attempted.append(url.absoluteString)
        return false
    }
    expect(!failed && attempted == expected, "both settings links fail: \(pane)")
}
print("PASS test_settings_links_and_fallback: five targets including Privacy_LocalNetwork, direct success, homepage fallback, total failure")
''', dashboard="")


def test_native_guide():
    output = ROOT / "build/permissions-preview"
    output.mkdir(parents=True, exist_ok=True)
    fixture.compile_run(r'''
let app = NSApplication.shared
app.appearance = NSAppearance(named: .aqua)
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func descendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants($0) }
}
func settle(_ window: NSWindow) {
    pump(0.08)
    for _ in 0..<3 {
        window.contentView!.updateConstraintsForSubtreeIfNeeded()
        window.contentView!.layoutSubtreeIfNeeded()
    }
}
func capture(_ view: NSView, _ name: String) {
    let bounds = view.bounds
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(ceil(bounds.width * 2)), pixelsHigh: Int(ceil(bounds.height * 2)),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = bounds.size
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        context.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
    }
    NSGraphicsContext.restoreGraphicsState()
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        view.cacheDisplay(in: bounds, to: rep)
    }
    let data = rep.representation(using: .png, properties: [:])!
    expect(data.count > 4000, "nonempty permissions snapshot: \(name)")
    try! data.write(to: output.appendingPathComponent(name + ".png"))
}
func texts(_ window: NSWindow) -> [NSTextField] {
    descendants(window.contentView!).compactMap { $0 as? NSTextField }
}
func explanatoryTextFields(in root: NSView) -> [NSTextField] {
    descendants(root).compactMap { $0 as? NSTextField }.filter { label in
        var ancestor = label.superview
        while let view = ancestor {
            if view is NSButton { return false }
            ancestor = view.superview
        }
        return true
    }
}
func buttons(_ window: NSWindow) -> [NSButton] {
    descendants(window.contentView!).compactMap { $0 as? NSButton }
}
func viewContext(_ view: NSView) -> String {
    func identity(_ item: NSView) -> String {
        "type=\(type(of: item)), identifier=\(item.identifier?.rawValue ?? "nil"), hidden=\(item.isHidden)"
    }
    var ancestors: [String] = []
    var ancestor = view.superview
    while let item = ancestor {
        ancestors.append(identity(item))
        ancestor = item.superview
    }
    let text = (view as? NSTextField)?.stringValue ?? (view as? NSButton)?.title ?? ""
    return "text=\(text.debugDescription), \(identity(view)), hiddenOrAncestor=\(view.isHiddenOrHasHiddenAncestor), frame=\(view.frame), bounds=\(view.bounds), superview=\(ancestors.first ?? "nil"), ancestors=\(ancestors)"
}
func expectVisibleText(_ window: NSWindow, _ value: String, _ message: String) {
    guard let label = texts(window).first(where: { $0.stringValue == value && !$0.isHiddenOrHasHiddenAncestor }) else {
        expect(false, message + ": no visible match for \(value.debugDescription); labels:\n" + texts(window).map(viewContext).joined(separator: "\n"))
        return
    }
    let clip = descendants(window.contentView!).compactMap { $0 as? NSScrollView }.first!.contentView
    let rect = label.convert(label.bounds, to: clip)
    expect(clip.bounds.contains(rect), message + ": label=\(rect), clip=\(clip.bounds), \(viewContext(label))")
}

do {
    let root = NSView()
    let explanation = NSTextField(labelWithString: "Expected guide explanation")
    let button = NSButton(title: "Open System Settings", target: nil, action: nil)
    let buttonContent = NSView()
    let buttonText = NSTextField(labelWithString: button.title)
    root.addSubview(explanation)
    root.addSubview(button)
    button.addSubview(buttonContent)
    buttonContent.addSubview(buttonText)
    expect(button.window == nil && !buttonText.isHiddenOrHasHiddenAncestor, "regression button remains offscreen with visible text")
    let expected = Set([explanation.stringValue])
    let unfiltered = Set(descendants(root).compactMap { $0 as? NSTextField }
        .filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue))
    expect(unfiltered.subtracting(expected) == Set([button.title]), "unfiltered text walk reproduces unexpected button title")
    let classified = Set(explanatoryTextFields(in: root).filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue))
    expect(classified == expected, "button-owned descendants are actions rather than explanations")
    let unknown = NSTextField(labelWithString: "Unexpected verified access")
    root.addSubview(unknown)
    expect(!unknown.isHiddenOrHasHiddenAncestor, "unknown explanatory sibling remains visible")
    let unexpected = Set(explanatoryTextFields(in: root).filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue)).subtracting(expected)
    expect(unexpected == Set([unknown.stringValue]), "unknown visible explanatory status remains detected")
    print("PASS test_text_ownership: unfilteredUnexpected=\(unfiltered.subtracting(expected).sorted()), classifiedUnexpected=\(classified.subtracting(expected).sorted()), withUnknownSibling=\(unexpected.sorted())")
}

Localization.shared.apply(language: .english)
let guide = PermissionsWindowController.shared
let window = guide.window!
window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
expect(PermissionsWindowController.guideVersion == 1, "public guide version")
expect(window.contentView!.frame.size == NSSize(width: 620, height: 560), "initial content size")
expect(window.contentMinSize == NSSize(width: 520, height: 460), "minimum content size")
expect(!window.isReleasedWhenClosed, "window survives close")
expect(window.styleMask.contains(.resizable) && window.styleMask.contains(.closable), "native resizable closable window")
expect(app.modalWindow == nil && window.sheetParent == nil, "nonmodal guide")
settle(window)
for key: Localization.Key in [.permissionsTitle, .permissionsIntro, .permissionsFullDisk] {
    expectVisibleText(window, L(key), "initially visible top content")
}
capture(window.contentView!, "english-620x560-initial")
print("PASS test_initial_scroll_position: title, intro and Full Disk Access visible before scrolling")

guide.showGuide()
guide.showGuide()
expect(PermissionsFixture.shownWindows == [ObjectIdentifier(window), ObjectIdentifier(window)], "repeated show reuses window")
expect(PermissionsFixture.activationCalls == 2, "show activates via inert boundary")
expect(PermissionsFixture.openedURLs.isEmpty && PermissionsFixture.revealedURLs.isEmpty, "show has no permissions side effects")

let expectedPanes = ["Privacy_AllFiles", "Privacy_Automation", "Privacy_Photos", "Privacy_Media", "Privacy_LocalNetwork"]
let openButtons = buttons(window).filter { $0.title == L(.permissionsOpenSettings) }.sorted { $0.tag < $1.tag }
expect(openButtons.count == 5, "five settings actions")
for (index, button) in openButtons.enumerated() {
    PermissionsFixture.openedURLs = []
    PermissionsFixture.openResults = [true]
    button.performClick(nil)
    expect(PermissionsFixture.openedURLs.map(\.absoluteString) == ["x-apple.systempreferences:com.apple.preference.security?" + expectedPanes[index]], "production button target: \(index)")
}
PermissionsFixture.openedURLs = []
for index in [4, 0] {
    PermissionsFixture.openedURLs = []
    PermissionsFixture.openResults = [false, true]
    openButtons[index].performClick(nil)
    expect(PermissionsFixture.openedURLs.map(\.absoluteString) == ["x-apple.systempreferences:com.apple.preference.security?" + expectedPanes[index], "x-apple.systempreferences:com.apple.preference.security"], "button uses homepage fallback: \(expectedPanes[index])")
    PermissionsFixture.openResults = [false, false]
    openButtons[index].performClick(nil)
    settle(window)
    expect(texts(window).contains { $0.stringValue == L(.permissionsOpenFailed) && !$0.isHiddenOrHasHiddenAncestor }, "inline error after both URLs fail: \(expectedPanes[index])")
    expectVisibleText(window, L(.permissionsOpenFailed), "total-failure feedback visible: \(expectedPanes[index])")
}
capture(window.contentView!, "english-620x560-failure")
expectVisibleText(window, L(.permissionsOpenFailed), "total-failure feedback visible after top FDA click")
Localization.shared.apply(language: .chinese)
settle(window)
expect(window.title == "权限与访问", "visible title follows language")
expect(texts(window).contains { $0.stringValue == "无法打开系统设置。请按所需权限下方的手动路径查找。" && !$0.isHiddenOrHasHiddenAncestor }, "visible error follows language")
expectVisibleText(window, L(.permissionsOpenFailed), "failure feedback remains visible after language change")
capture(window.contentView!, "chinese-620x560-failure")
expect(texts(window).contains { $0.stringValue == "按需要设置权限。授权通常授予实际发起请求的程序；从不同位置启动 DSH，系统显示的程序名称可能不同。" }, "approved Chinese intro")
PermissionsFixture.openResults = [true]
buttons(window).first { $0.title == L(.permissionsOpenSettings) }!.performClick(nil)
settle(window)
expect(!texts(window).contains { $0.stringValue == L(.permissionsOpenFailed) && !$0.isHiddenOrHasHiddenAncestor }, "successful open clears error without claiming access")
buttons(window).first { $0.title == L(.permissionsRevealApp) }!.performClick(nil)
expect(PermissionsFixture.revealedURLs == [Bundle.main.bundleURL], "Finder action uses current bundle URL")
let openCount = PermissionsFixture.openedURLs.count
let revealCount = PermissionsFixture.revealedURLs.count
buttons(window).first { $0.title == L(.permissionsLater) }!.performClick(nil)
expect(!window.isVisible && guide.window === window, "Set Up Later closes reusable window")
guide.showGuide()
expect(PermissionsFixture.shownWindows.last == ObjectIdentifier(window), "reopen after Set Up Later reuses window")
window.performClose(nil)
guide.showGuide()
expect(guide.window === window && PermissionsFixture.shownWindows.count == 4, "native close and reopen reuse window")
expect(PermissionsFixture.openedURLs.count == openCount && PermissionsFixture.revealedURLs.count == revealCount, "close/reopen has no permissions side effects")
print("PASS test_native_actions: settings buttons, fallback/error, Finder bundle, show/close/reopen, live language")

for (language, name, paths) in [
    (AppLanguage.english, "english", ["Full Disk Access", "Automation", "Photos", "Media & Apple Music", "Local Network"].map { "System Settings → Privacy & Security → " + $0 }),
    (AppLanguage.chinese, "chinese", ["完全磁盘访问", "自动化", "照片", "媒体与 Apple Music", "本地网络"].map { "系统设置 → 隐私与安全性 → " + $0 })
] {
    Localization.shared.apply(language: language)
    expect(PermissionSettingsTarget.allCases.map(\.manualPath) == paths, "localized manual paths: \(name)")
    let network = PermissionSettingsTarget.localNetwork
    expect(network.title == (language == .english ? "Local Network" : "本地网络"), "localized Local Network title: \(name)")
    let requiredNetworkCopy = language == .english
        ? ["discovering and connecting", "local network devices and services", "macOS 15", "actual requesting program listed by macOS", "does not guarantee", "Node, Terminal or other processes", "manual path", "older macOS versions"]
        : ["发现和连接局域网设备与服务", "macOS 15 起", "系统实际列出的申请程序", "不保证", "Node、终端或其他进程", "手动路径", "旧版 macOS"]
    expect(requiredNetworkCopy.allSatisfy { network.explanation.contains($0) }, "localized Local Network scope, version, requester and fallback guidance: \(name)")
    for size in [NSSize(width: 620, height: 560), NSSize(width: 520, height: 460)] {
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        settle(window)
        let content = window.contentView!
        let scroll = descendants(content).compactMap { $0 as? NSScrollView }.first!
        let document = scroll.documentView!
        let clip = scroll.contentView
        let visibleTexts = explanatoryTextFields(in: content).filter { !$0.isHiddenOrHasHiddenAncestor }
        let controls = buttons(window)
        let geometry = { "language=\(name), size=\(size), scrollerStyle=\(scroll.scrollerStyle), content.frame=\(content.frame), content.bounds=\(content.bounds), scroll.frame=\(scroll.frame), scroll.bounds=\(scroll.bounds), document.frame=\(document.frame), document.bounds=\(document.bounds), clip.frame=\(clip.frame), clip.bounds=\(clip.bounds)" }
        print("GEOMETRY permissions guide: \(geometry())")
        expect(scroll.hasVerticalScroller, "scrollable permissions document")
        expect(abs(document.frame.width - clip.bounds.width) < 1, "no horizontal overflow: \(geometry())")
        expect(document.frame.height > clip.bounds.height, "long guide needs scrolling")
        expect(controls.count == 7, "complete guide controls: count=\(controls.count), controls=\(controls.map(viewContext)); \(geometry())")
        let expectedButtonTitles = Array(repeating: L(.permissionsOpenSettings), count: 5) + [L(.permissionsRevealApp), L(.permissionsLater)]
        expect(controls.map(\.title).sorted() == expectedButtonTitles.sorted(), "known action titles and counts: controls=\(controls.map(viewContext)); \(geometry())")
        expect(controls.allSatisfy { !$0.isHiddenOrHasHiddenAncestor }, "all guide actions remain visible: controls=\(controls.map(viewContext)); \(geometry())")
        let explanatoryTexts = [L(.permissionsTitle), L(.permissionsIntro), L(.permissionsNote)]
            + PermissionSettingsTarget.allCases.flatMap { [$0.title, $0.explanation, $0.manualPath] }
        let missingTexts = Set(explanatoryTexts).subtracting(Set(visibleTexts.map(\.stringValue))).sorted()
        let unexpectedTexts = Set(visibleTexts.map(\.stringValue)).subtracting(Set(explanatoryTexts)).sorted()
        let textDifference = "missing=\(missingTexts), unexpected=\(unexpectedTexts)"
        let labelContext = { texts(window).map(viewContext).joined(separator: "\n") }
        print("TEXTS permissions guide: language=\(name), size=\(size), \(textDifference)")
        expect(Set(visibleTexts.map(\.stringValue)) == Set(explanatoryTexts), "explanations only; no verified authorization status: \(textDifference); \(geometry()); labels:\n\(labelContext())")
        expect(!descendants(content).contains { $0 is NSProgressIndicator }, "no permissions completion indicator: \(geometry()); indicators=\(descendants(content).filter { $0 is NSProgressIndicator }.map(viewContext))")
        for target in PermissionSettingsTarget.allCases {
            expect(visibleTexts.contains { $0.stringValue == target.title }, "permission heading: \(target.title); labels:\n\(labelContext())")
            expect(visibleTexts.contains { $0.stringValue == target.explanation }, "permission explanation: \(target.title); labels:\n\(labelContext())")
            expect(visibleTexts.contains { $0.stringValue == target.manualPath }, "manual path: \(target.title); labels:\n\(labelContext())")
        }
        for view in descendants(document) where !view.isHiddenOrHasHiddenAncestor && (view is NSTextField || view is NSButton) {
            let rect = view.convert(view.bounds, to: document)
            expect(rect.width > 0 && rect.height > 0 && rect.minX >= -1 && rect.maxX <= document.bounds.width + 1 && rect.minY >= -1 && rect.maxY <= document.bounds.height + 1, "control stays inside document: rect=\(rect), \(viewContext(view)); \(geometry())")
            if let label = view as? NSTextField, let font = label.font {
                let required = (label.stringValue as NSString).boundingRect(
                    with: NSSize(width: max(1, label.bounds.width - 4), height: 10000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
                expect(label.bounds.height + 2 >= ceil(required), "wrapped label is not clipped: requiredHeight=\(ceil(required)), font=\(font.fontName), fontSize=\(font.pointSize), \(viewContext(label)); \(geometry())")
            }
        }
        for value in [network.title, network.explanation, network.manualPath] {
            let label = visibleTexts.first { $0.stringValue == value }!
            label.scrollToVisible(label.bounds)
            scroll.reflectScrolledClipView(clip)
            expectVisibleText(window, value, "Local Network content reachable by scrolling: \(name)")
        }
        let networkButton = controls.first { $0.title == L(.permissionsOpenSettings) && $0.tag == 4 }!
        networkButton.scrollToVisible(networkButton.bounds)
        scroll.reflectScrolledClipView(clip)
        expect(clip.bounds.contains(networkButton.convert(networkButton.bounds, to: clip)), "Local Network settings button reachable by scrolling: rect=\(networkButton.convert(networkButton.bounds, to: clip)), \(viewContext(networkButton)); \(geometry())")
        let later = controls.first { $0.title == L(.permissionsLater) }!
        expect(content.bounds.contains(later.convert(later.bounds, to: content)), "Set Up Later stays visible: rect=\(later.convert(later.bounds, to: content)), \(viewContext(later)); \(geometry())")
        let stem = "\(name)-\(Int(size.width))x\(Int(size.height))"
        let first = visibleTexts.first { $0.stringValue == L(.permissionsTitle) }!
        first.scrollToVisible(first.bounds)
        scroll.reflectScrolledClipView(clip)
        expect(first.convert(first.bounds, to: clip).intersects(clip.bounds), "top of guide reachable by scrolling: rect=\(first.convert(first.bounds, to: clip)), \(viewContext(first)); \(geometry())")
        capture(content, stem + "-top")
        let last = visibleTexts.first { $0.stringValue == L(.permissionsNote) }!
        last.scrollToVisible(last.bounds)
        scroll.reflectScrolledClipView(clip)
        expect(last.convert(last.bounds, to: clip).intersects(clip.bounds), "end of guide reachable by scrolling: last=\(last.convert(last.bounds, to: clip)), \(viewContext(last)); \(geometry())")
        capture(content, stem + "-bottom")
        capture(document, stem + "-document")
        print("PASS test_native_layout: \(stem), all controls present, wrapped text fits, scroll end reachable; 3 PNGs")
        let originalStyle = scroll.scrollerStyle
        for style in [NSScroller.Style.overlay, .legacy] {
            scroll.scrollerStyle = style
            settle(window)
            expect(abs(document.frame.width - clip.bounds.width) < 1, "no horizontal overflow after scroller transition: \(geometry())")
            print("PASS test_scroller_layout: \(geometry())")
        }
        scroll.scrollerStyle = originalStyle
        settle(window)
    }
}
window.close()
var disposable: PermissionsWindowController? = PermissionsWindowController()
weak var released = disposable
disposable = nil
expect(released == nil, "language observer does not retain controller")
Localization.shared.apply(language: .english)
print("PASS test_language_observer_lifetime: controller releases and later language change is safe")
''', dashboard="", arguments=[output])


if __name__ == "__main__":
    test_first_display_version_and_termination()
    test_manual_settings_entry()
    test_settings_links_and_fallback()
    test_native_guide()
