#!/usr/bin/env python3
"""Exercise actual progress presentation/AppKit methods with inert dependencies."""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("dashboard_fixture", ROOT / "Tests/dashboard-ui-fixture.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
source = (ROOT / "Sources/DashboardWindow.swift").read_text()
presentation = fixture.extract(source, r"^struct InstallProgressPresentation: Equatable \{.*?^}$")
presentation += "\n" + fixture.extract(source, r"^func installProgressPresentation\(.*?^}$")
methods = "\n".join(fixture.extract(source, rf"^    {signature}.*?^    }}$") for signature in [
    r"private func refreshInstallProgress\(", r"@objc private func stopInstallProgress\(",
    r"@objc private func didClickCancelInstall\(", r"@objc private func didClickInstallDetails\(",
]).replace("private func", "func")
# Control spies observe animation decisions; only the system preference read is
# injected so both accessibility branches run without changing host defaults.
methods = methods.replace("NSWorkspace.shared.accessibilityDisplayShouldReduceMotion", "reduceMotion")
harness = r'''
import Cocoa
final class ProgressSpy: NSProgressIndicator {
    var starts = 0
    var stops = 0
    override func startAnimation(_ sender: Any?) { starts += 1 }
    override func stopAnimation(_ sender: Any?) { stops += 1 }
}
struct PanelVisibility { var isVisible = true }
final class ProgressHarness: NSObject {
    var window: PanelVisibility? = PanelVisibility()
    let tagInstallProgress = ProgressSpy()
    let tagInstallStatusLabel = NSTextField(labelWithString: "")
    let tagInstallMetricsLabel = NSTextField(labelWithString: "")
    var tagInstallTimer: Timer?
    let installTaskStack = NSStackView()
    let tagCancelButton = NSButton()
    let tagDetailsButton = NSButton()
    let tagLogScroll = NSScrollView()
    let tagLogText = NSTextView()
    var showsInstallDetails = false
    var installOutcome: Localization.Key?
    var reduceMotion = false
'''
checks = r'''
_ = NSApplication.shared
Localization.shared.apply(language: .english)
let model = DshVersionController.shared
let panel = ProgressHarness()
panel.refreshInstallProgress()
expect(panel.installTaskStack.isHidden && panel.tagInstallTimer == nil, "idle task visible or ticking")
let now: TimeInterval = 100
var snapshot = InstallActivity(tag: "next", startedAt: 35, phase: .downloading,
    bytesReceived: 1_000_000, totalBytes: 4_000_000, bytesPerSecond: 500_000,
    outputTail: "first\nlast", version: "2.0.0")
let known = installProgressPresentation(activity: snapshot, now: now)
expect(known.fraction == 0.25 && known.canCancel, "known fraction/cancel is wrong")
for text in ["1 MB / 4 MB", "25%", "500 KB/s", "Elapsed 1:05", "About 0:06 remaining"] {
    expect(known.metrics.contains(text), "missing real download metric: \(text); got \(known.metrics)")
}
expect(known.title == "Downloading DSH package · 2.0.0", "download phase/version title")
snapshot.totalBytes = nil
let unknown = installProgressPresentation(activity: snapshot, now: now)
expect(unknown.fraction == nil && unknown.metrics.contains("1 MB downloaded"), "unknown total fabricated progress")
expect(!unknown.metrics.contains("%") && !unknown.metrics.contains("remaining"), "unknown total shows percent/ETA")
for badRate in [0, -1, Double.nan, Double.infinity] {
    snapshot.bytesPerSecond = badRate
    let waiting = installProgressPresentation(activity: snapshot, now: now)
    expect(waiting.metrics.contains("Waiting for data") && !waiting.metrics.contains("/s"), "invalid rate rendered")
}
snapshot.totalBytes = 0
snapshot.bytesReceived = -1
expect(installProgressPresentation(activity: snapshot, now: now).fraction == nil, "zero total fabricated fraction")
snapshot.totalBytes = 10
snapshot.bytesReceived = 20
snapshot.bytesPerSecond = 1
expect(installProgressPresentation(activity: snapshot, now: now).fraction == 1, "fraction exceeds one")
for phase: InstallActivity.Phase in [.resolving, .verifying, .installing, .cancelling] {
    snapshot.phase = phase
    let result = installProgressPresentation(activity: snapshot, now: now)
    expect(result.fraction == nil && result.metrics == "Elapsed 1:05", "non-download phase shows download telemetry")
    expect(result.canCancel == (phase != .cancelling), "cancelling remains cancellable")
}
snapshot.phase = .resolving
var live = InstallActivity(tag: "next", startedAt: ProcessInfo.processInfo.systemUptime,
    phase: .resolving, outputTail: "first\nlast")
model.installActivity = live
panel.refreshInstallProgress()
let timer = panel.tagInstallTimer
expect(timer != nil && timer!.isValid, "visible install did not schedule timer")
expect(!panel.installTaskStack.isHidden && !panel.tagInstallProgress.isHidden, "active task hidden")
expect(panel.tagInstallStatusLabel.stringValue.contains("next"), "resolving lost channel")
expect(panel.tagInstallProgress.starts > 0, "indeterminate progress did not animate")
panel.reduceMotion = true
let starts = panel.tagInstallProgress.starts
panel.refreshInstallProgress()
expect(panel.tagInstallProgress.starts == starts && panel.tagInstallProgress.stops > 0, "reduce motion still animated")
// Tracking is a common run-loop mode: this catches default-mode-only timers.
pump(1.15, mode: .eventTracking)
expect(panel.tagInstallMetricsLabel.stringValue.contains("0:01"), "common-mode timer froze during tracking")
expect(panel.tagInstallTimer === timer, "refresh duplicated timer")
panel.showsInstallDetails = true
panel.refreshInstallProgress()
expect(!panel.tagLogScroll.isHidden && panel.tagLogText.string == "first\nlast", "live log unavailable")
panel.tagLogText.setSelectedRange(NSRange(location: 1, length: 3))
panel.refreshInstallProgress()
expect(panel.tagLogText.selectedRange() == NSRange(location: 1, length: 3), "unchanged log reset selection")
// The UI consumes the controller's already bounded tail, including Unicode.
live.outputTail = String(repeating: "x", count: 65_520) + "\n中文 tail"
model.installActivity = live
panel.refreshInstallProgress()
expect(panel.tagLogText.string == live.outputTail && panel.tagLogText.string.utf8.count <= 65_536, "bounded log was expanded or lost")
panel.didClickCancelInstall()
expect(model.cancelCalls == 1 && !panel.tagCancelButton.isEnabled, "cancel did not invoke controller/disable button")
expect(panel.tagCancelButton.title == "Cancelling…", "cancel state title")
let preserved = model.installActivity
Localization.shared.apply(language: .chinese)
panel.refreshInstallProgress()
expect(panel.tagInstallStatusLabel.stringValue == "正在取消…", "real Chinese phase translation missing")
expect(panel.tagCancelButton.title == "正在取消…" && panel.tagDetailsButton.title == "收起安装日志", "task controls not localized")
expect(model.installActivity == preserved, "language reset activity")
panel.stopInstallProgress()
panel.window?.isVisible = false
expect(panel.tagInstallTimer == nil && !timer!.isValid, "close leaked timer")
panel.refreshInstallProgress()
expect(panel.tagInstallTimer == nil, "hidden window restarted timer")
panel.window?.isVisible = true
panel.refreshInstallProgress()
expect(panel.tagInstallTimer != nil && model.installActivity == preserved, "reopen lost task/timer")
model.lastInstallLog = "retained final log"
model.installActivity = nil
for outcome: Localization.Key in [.installFinished, .installStopped, .installCancelled] {
    panel.installOutcome = outcome
    panel.refreshInstallProgress()
    expect(panel.tagInstallStatusLabel.stringValue == L(outcome), "terminal outcome not rendered")
    expect(panel.tagInstallTimer == nil && panel.tagInstallProgress.isHidden && panel.tagCancelButton.isHidden,
           "terminal task still ticking/active")
    expect(!panel.installTaskStack.isHidden && panel.tagLogText.string == "retained final log", "terminal log inaccessible")
}
panel.didClickInstallDetails()
expect(panel.tagLogScroll.isHidden, "log disclosure did not collapse")
print("PASS install progress: actual presentation, AppKit render, common-mode timer, cancel, localization, reduced motion, bounded log/selection, outcomes, close/reopen")
'''
fixture.compile_run(checks, "import Cocoa\n" + presentation + "\n" + harness + methods + "\n}\n")
