"""Inert dependencies for compiling actual dashboard UI; no app entry point."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def extract(source, pattern):
    match = re.search(pattern, source, re.MULTILINE | re.DOTALL)
    if not match:
        raise AssertionError(f"production source not found: {pattern}")
    return match.group(0)


STUBS = r'''
import Cocoa
import Carbon
final class SettingsManager {
    static let shared = SettingsManager()
    var language: AppLanguage = .english
    var preferredDshTag: String? = "next"
    var port = 3080
    var globalHotKeyDisplayString = "⌃ ⌥ ⌘ D"
    var isLaunchAtLoginEnabled = false
    var autoRestartEnabled = true
    var onHotKeyChanged: (() -> Void)?
    func addPortObserver(_ callback: @escaping (Int) -> Void) -> UUID { UUID() }
    func updateGlobalHotKey(keyCode: UInt32, modifiers: UInt32, display: String) {}
    func resetHotKeyToDefault() {}
}
final class DshVersionController {
    static let shared = DshVersionController()
    var installActivity: InstallActivity?
    var isTerminating = false
    var lastInstallLog = ""
    var isInstalling: Bool { installActivity != nil }
    var cancelCalls = 0
    func cancelInstall() { cancelCalls += 1; installActivity?.phase = .cancelling }
    static func validTag(_ tag: String) -> Bool { true }
    static func installCommand(forTag tag: String) -> String? { "inert fixture" }
    func fetchTags(completion: @escaping (Result<[String: String], ProbeFailure>) -> Void) {
        completion(.success(["latest": "1.0.0", "next": "2.0.0"]))
    }
    func install(tag: String, completion: @escaping (Result<String, Error>) -> Void) {}
}
enum ServicePhase {
    case running, checking, starting, stopping, restarting, portConflict, error, stopped
    var isBusy: Bool { [.starting, .stopping, .restarting].contains(self) }
}
struct ServiceSnapshot {
    var phase: ServicePhase = .stopped
    var port = 3080
    var pid: Int32? = nil
    var uptime: TimeInterval? = nil
    var dshVersion: String? = "1.0.0"
    var message: String? = nil
    var dshPath: String? = "/fixture/bin/dsh"
    var isManaged = true
    var isRunning: Bool { phase == .running }
}
final class ServiceManager {
    static let shared = ServiceManager()
    var snapshot = ServiceSnapshot()
    var recoveryNotice: String? = nil
    var dshDetectionComplete = true
    var autoRestartEnabled = true
    var isRunning: Bool { snapshot.isRunning }
    var hasUnmanagedService = false
    func addStatusObserver(_ callback: @escaping (ServiceSnapshot) -> Void) -> UUID { UUID() }
    func detectDshInstallation(completion: ((String?) -> Void)? = nil) { completion?(snapshot.dshPath) }
    func openBrowser() {}
    func stopService(completion: (Bool, String?) -> Void) {}
    func startService(completion: (Bool, String?) -> Void) {}
    func restartService(completion: (Bool, String?) -> Void) {}
    func stopUnmanagedService(pid: Int32, completion: (Bool, String?) -> Void) {}
    func restartUnmanagedService(pid: Int32, completion: (Bool, String?) -> Void) {}
    func copyURLToClipboard() {}
    func copyDiagnosticsToClipboard() {}
    func cancelPendingAutoRestart() {}
}
final class UpdateManager {
    static let shared = UpdateManager()
    var currentVersion = "1.2.3"
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = true
    func checkForUpdates(_ sender: Any?) {}
}
final class HotKeyManager {
    static let shared = HotKeyManager()
    var lastRegistrationStatus: OSStatus? = nil
    func unregister(id: UInt32) {}
    func isAvailable(keyCode: UInt32, modifiers: UInt32) -> Bool { false }
}
final class ServiceNotifier {
    enum Availability {
        case available, unknown, denied, unusable
        var shortDescription: String { L(.notifAvailable) }
    }
    static let shared = ServiceNotifier()
    var availability = Availability.available
    func addObserver(_ callback: @escaping () -> Void) -> UUID { UUID() }
    func removeObserver(_ token: UUID) {}
    func requestAuthorizationIfNeeded(completion: () -> Void) {}
    func refreshAvailability() {}
    func openSystemNotificationSettings() {}
}
enum ExternalServicePrompt {
    enum Action { case stop, restart }
    static func confirm(action: Action, completion: (Bool) -> Void) {}
}
enum DshInstallAssistant { static func present() {} }
final class LogWindowController {
    static let shared = LogWindowController()
    func showWindow(_ sender: Any?) {}
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}
func pump(_ seconds: TimeInterval, mode: RunLoop.Mode = .default) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        _ = RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.01))
    }
}
'''


def compile_run(main, dashboard=None, full_dashboard=False, arguments=()):
    source = (ROOT / "Sources/DashboardWindow.swift").read_text()
    controller = (ROOT / "Sources/DshVersionController.swift").read_text()
    # Only value declarations are taken from the backend, never its controller.
    declarations = controller[:controller.index("final class DshVersionController {")]
    if full_dashboard:
        dashboard = source.replace("private ", "")
    with tempfile.TemporaryDirectory(prefix="dsh-dashboard-ui-") as directory:
        work = Path(directory)
        cache = work / "module-cache"
        cache.mkdir()
        (work / "Dashboard.swift").write_text(dashboard)
        (work / "Declarations.swift").write_text(declarations)
        (work / "Localization.swift").write_text((ROOT / "Sources/Localization.swift").read_text())
        (work / "Fixture.swift").write_text(STUBS)
        (work / "main.swift").write_text("import Cocoa\n" + main)
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cache),
                   SWIFT_MODULECACHE_PATH=str(cache))
        binary = work / "ui-check"
        subprocess.run(["swiftc", "-Onone", "-module-cache-path", str(cache),
                        *map(str, work.glob("*.swift")), "-o", str(binary)],
                       env=env, check=True, timeout=120)
        result = subprocess.run([str(binary), *map(str, arguments)], env=env,
                                capture_output=True, text=True, timeout=45)
        if result.returncode:
            raise AssertionError(f"AppKit fixture exited {result.returncode}:\n"
                                 + result.stdout + result.stderr)
        if "Unable to simultaneously satisfy constraints" in result.stderr:
            raise AssertionError(result.stderr)
        print(result.stdout, end="")
