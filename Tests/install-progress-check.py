#!/usr/bin/env python3
"""Run the actual AppKit progress renderer without a real window, npm or DSH."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("install_pipe", ROOT / "Tests/install-pipe-check.py")
pipe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pipe)
source = (ROOT / "Sources/DashboardWindow.swift").read_text()
activity = pipe.extract((ROOT / "Sources/DshVersionController.swift").read_text(),
                        r"^struct InstallActivity: Equatable \{.*?^}$")
methods = "\n".join(pipe.extract(source, rf"^    {signature}.*?^    }}$") for signature in [
    r"private func refreshInstallProgress\(", r"@objc private func stopInstallProgress\(",
])
# Access changes apply only to the harness, leaving production behavior intact.
methods = methods.replace("private func", "func")
harness = r'''
import Cocoa
final class DshVersionController {
    static let shared = DshVersionController()
    var installActivity: InstallActivity?
}
enum Key { case installProgressStatus }
var chinese = false
func L(_ key: Key, _ values: [String: String]) -> String {
    "\(chinese ? "正在安装" : "Installing") \(values["tag"]!) · \(values["elapsed"]!)"
}
struct PanelVisibility { var isVisible = true }
final class ProgressHarness: NSObject {
    var window: PanelVisibility? = PanelVisibility()
    let tagInstallProgress = NSProgressIndicator()
    let tagInstallStatusLabel = NSTextField(labelWithString: "")
    var tagInstallTimer: Timer?
    let row = NSView()
    let card = NSView()
    var tagRowHeightConstraint: NSLayoutConstraint?
    var preferencesCardHeightConstraint: NSLayoutConstraint?
    override init() {
        super.init()
        tagRowHeightConstraint = row.heightAnchor.constraint(equalToConstant: 54)
        preferencesCardHeightConstraint = card.heightAnchor.constraint(equalToConstant: 541)
        tagInstallProgress.isIndeterminate = true
    }
'''
checks = r'''
func expect(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}
func pump(_ seconds: TimeInterval) {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}
let panel = ProgressHarness()
panel.refreshInstallProgress()
expect(panel.tagInstallProgress.isHidden && panel.tagInstallTimer == nil, "idle progress is active")
let start = ProcessInfo.processInfo.systemUptime
let activity = InstallActivity(tag: "next", startedAt: start)
DshVersionController.shared.installActivity = activity
panel.refreshInstallProgress()
let timer = panel.tagInstallTimer
expect(timer != nil && timer!.isValid, "install did not schedule a timer")
expect(!panel.tagInstallProgress.isHidden, "install bar stayed hidden")
expect(panel.tagInstallStatusLabel.stringValue.contains("next"), "wrong installing tag")
expect(panel.tagRowHeightConstraint?.constant == 92, "row did not expand")
expect(panel.preferencesCardHeightConstraint?.constant == 579, "scroll card did not expand")
pump(1.15)
expect(panel.tagInstallStatusLabel.stringValue.hasSuffix("0:01"), "timer did not advance without output")
expect(panel.tagInstallTimer === timer, "refresh duplicated the timer")
chinese = true
panel.refreshInstallProgress()
expect(panel.tagInstallStatusLabel.stringValue.hasPrefix("正在安装 next"), "language rebuild lost status")
expect(DshVersionController.shared.installActivity == activity, "language change reset install time")
panel.stopInstallProgress()
panel.window?.isVisible = false
expect(panel.tagInstallTimer == nil && !timer!.isValid, "closing leaked the timer")
panel.refreshInstallProgress()
expect(panel.tagInstallTimer == nil, "hidden window restarted the timer")
panel.window?.isVisible = true
panel.refreshInstallProgress()
expect(panel.tagInstallTimer != nil, "reopening did not resume feedback")
expect(DshVersionController.shared.installActivity == activity, "reopening reset install time")
DshVersionController.shared.installActivity = nil
panel.refreshInstallProgress()
expect(panel.tagInstallTimer == nil, "completion leaked the timer")
expect(panel.tagInstallProgress.isHidden && panel.tagInstallStatusLabel.isHidden, "completed progress stayed visible")
expect(panel.tagRowHeightConstraint?.constant == 54, "completed row stayed expanded")
expect(panel.preferencesCardHeightConstraint?.constant == 541, "completed card stayed expanded")
print("PASS install progress: AppKit controls, elapsed timer, language, hide/reopen, cleanup")
'''
with tempfile.TemporaryDirectory(prefix="dsh-install-progress-") as directory:
    work = Path(directory)
    swift = work / "main.swift"
    swift.write_text("import Cocoa\n" + activity + "\n" + harness + methods + "\n}\n" + checks)
    cache = work / "module-cache"
    cache.mkdir()
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cache))
    binary = work / "progress-check"
    subprocess.run(["swiftc", "-Onone", "-module-cache-path", str(cache), str(swift),
                    "-o", str(binary)], env=env, check=True)
    pipe.run_fixture([str(binary)], env)
