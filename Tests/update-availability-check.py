#!/usr/bin/env python3
"""Exercise the production update action; no live updater or services."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def method(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for end in range(opening, len(source)):
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
            if depth == 0:
                return source[start:end + 1]
    raise AssertionError(f"Unclosed production method: {signature}")


def main() -> None:
    wrapper = (ROOT / "Sources/UpdateManager.swift").read_text()
    action = method(wrapper, "func checkForUpdates(_ sender: Any?)")
    fixture = r'''
import Foundation
final class ControllerStub {
    var calls = 0
    var lastSender: Any?
    func checkForUpdates(_ sender: Any?) { calls += 1; lastSender = sender }
}
final class UpdateProbe {
    var canCheckForUpdates = false
    let controller = ControllerStub()
ACTION
}
func expect(_ condition: Bool, _ message: String = "update action assertion failed") {
    if !condition { print("FAIL \(message)"); exit(1) }
}
let probe = UpdateProbe()
let sender = NSObject()
probe.checkForUpdates(sender)
expect(probe.controller.calls == 0, "unavailable action must not reach Sparkle")
probe.canCheckForUpdates = true
probe.checkForUpdates(sender)
expect(probe.controller.calls == 1)
expect((probe.controller.lastSender as? NSObject) === sender)
probe.canCheckForUpdates = false
probe.checkForUpdates(nil)
expect(probe.controller.calls == 1, "stale clicks must be rejected")
probe.canCheckForUpdates = true
probe.checkForUpdates(nil)
expect(probe.controller.calls == 2 && probe.controller.lastSender == nil)
print("PASS production update action preserves sender and respects availability")
'''.replace("ACTION", action)
    with tempfile.TemporaryDirectory(prefix="dshbar-update-availability-") as directory:
        d = Path(directory)
        source, binary = d / "probe.swift", d / "probe"
        source.write_text(fixture)
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(d / "modulecache"))
        subprocess.run(["xcrun", "swiftc", str(source), "-o", str(binary)],
                       env=env, check=True, timeout=120)
        subprocess.run([str(binary)], env=env, check=True, timeout=30)

    dashboard = (ROOT / "Sources/DashboardWindow.swift").read_text()
    expected = "updateCheckButton.isEnabled = UpdateManager.shared.canCheckForUpdates"
    for signature in ("private func makePreferencesCard() -> NSView",
                      "func updateState(_ snapshot: ServiceSnapshot)"):
        assert expected in method(dashboard, signature), f"Missing availability refresh in {signature}"
    assert dashboard.count("UpdateManager.shared.automaticallyChecksForUpdates =") == 1
    print("PASS Dashboard initial/refresh availability and single preference write")


if __name__ == "__main__":
    main()
