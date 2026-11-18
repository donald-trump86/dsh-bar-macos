#!/usr/bin/env python3
"""Exercise browser detection and Open Web routing in an inert stub world.

No browser is launched and the system default handler is never read: the
production blocks are spliced next to a fake NSWorkspace, and the applications
they inspect are synthesized .app directories holding only an Info.plist inside
this test's temporary directory.
"""
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


STUBS = r'''
import Foundation

final class SettingsManager {
    static let shared = SettingsManager()
    var preferredBrowserBundleIdentifier: String? = nil
}

final class NSWorkspace {
    final class OpenConfiguration {}
    static let shared = NSWorkspace()
    var candidates: [URL] = []
    var resolvable: [String: URL] = [:]
    var defaultApplication: URL?
    var openedDefaultURLs: [URL] = []
    var openedApps: [(app: URL, url: URL)] = []
    func urlsForApplications(toOpen url: URL) -> [URL] { candidates }
    func urlForApplication(withBundleIdentifier id: String) -> URL? { resolvable[id] }
    func urlForApplication(toOpen url: URL) -> URL? { defaultApplication }
    func open(_ url: URL) { openedDefaultURLs.append(url) }
    func open(_ urls: [URL], withApplicationAt app: URL, configuration: OpenConfiguration) {
        for url in urls { openedApps.append((app, url)) }
    }
}
'''

CHECKS = r'''
func expect(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}

/// A bundle-shaped directory with only Contents/Info.plist: Bundle(url:) reads
/// the identifier, the scheme groups and the document types from it.
func makeApplication(_ directory: URL, named name: String, identifier: String?,
                     schemeGroups: [[String]], declaresHTML: Bool) -> URL {
    let app = directory.appendingPathComponent(name).appendingPathExtension("app")
    let contents = app.appendingPathComponent("Contents")
    try! FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var plist: [String: Any] = [
        // Deliberately different from the filename so display names cannot come
        // from here by accident.
        "CFBundleName": "Bundle Name Only",
        "CFBundleURLTypes": schemeGroups.map {
            ["CFBundleURLName": "scheme group", "CFBundleURLSchemes": $0]
        },
        "CFBundleDocumentTypes": declaresHTML
            ? [["CFBundleTypeName": "HTML page",
                "CFBundleTypeExtensions": ["html", "htm", "shtml", "xhtml", "xht"],
                "LSItemContentTypes": ["public.html"]]]
            : [["CFBundleTypeName": "Plain text",
                "CFBundleTypeExtensions": ["txt"],
                "LSItemContentTypes": ["public.plain-text"]]],
    ]
    if let identifier { plist["CFBundleIdentifier"] = identifier }
    let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try! data.write(to: contents.appendingPathComponent("Info.plist"))
    return app
}

let workspace = NSWorkspace.shared
let applications = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    .appendingPathComponent("applications")
try! FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)

// chrome: browser. terminal: ssh/telnet client that claims http/https but no
// html. iterm: claims http/https, public.html AND ssh. nohtml: no html. noid:
// browser-shaped but with no CFBundleIdentifier to dedupe on.
let chrome = makeApplication(applications, named: "Google Chrome",
    identifier: "com.example.chrome", schemeGroups: [["http", "https"], ["file"]],
    declaresHTML: true)
let terminal = makeApplication(applications, named: "Terminal Stand-in",
    identifier: "com.example.terminal", schemeGroups: [["http", "https"], ["ssh", "telnet"]],
    declaresHTML: false)
let iterm = makeApplication(applications, named: "iTerm Stand-in",
    identifier: "com.example.iterm", schemeGroups: [["http", "https"], ["ssh"]],
    declaresHTML: true)
let nohtml = makeApplication(applications, named: "No HTML Stand-in",
    identifier: "com.example.nohtml", schemeGroups: [["http", "https"]],
    declaresHTML: false)
let noIdentifier = makeApplication(applications, named: "No Identifier Stand-in",
    identifier: nil, schemeGroups: [["http", "https"]], declaresHTML: true)

// Listed out of order: filtering and sorting must not depend on input order.
workspace.candidates = [terminal, chrome, iterm, nohtml, noIdentifier]
workspace.defaultApplication = chrome
let launcher = BrowserLauncher.shared

expect(launcher.options().map(\.bundleIdentifier) == ["com.example.chrome"],
       "filter kept a non-browser")
expect(launcher.options().map(\.displayName) == ["Google Chrome"],
       "display name must come from the .app filename")
expect(launcher.systemDefaultBrowserName() == "Google Chrome",
       "system default name missing")

let brave = makeApplication(applications, named: "Brave Browser",
    identifier: "com.example.brave", schemeGroups: [["http", "https"], ["file"]],
    declaresHTML: true)
workspace.candidates.append(brave)
expect(launcher.options().map(\.displayName) == ["Brave Browser", "Google Chrome"],
       "options must sort by display name")

// Firefox and Zen register http and https as separate groups, so the web-scheme
// test has to run over the union; "at least one group holds both" drops them.
let firefox = makeApplication(applications, named: "Firefox",
    identifier: "com.example.firefox", schemeGroups: [["http"], ["https"], ["file"]],
    declaresHTML: true)
let zen = makeApplication(applications, named: "Zen",
    identifier: "com.example.zen", schemeGroups: [["http"], ["https"], ["file"]],
    declaresHTML: true)
workspace.candidates = [zen, firefox]
expect(launcher.options().map(\.bundleIdentifier) == ["com.example.firefox", "com.example.zen"],
       "http and https declared in separate groups must still count as a browser")
expect(launcher.options().map(\.displayName) == ["Firefox", "Zen"],
       "firefox-shaped options must sort by display name")

// Two bundles with one identifier are one picker row.
let duplicate = makeApplication(applications, named: "Duplicate Chrome",
    identifier: "com.example.chrome", schemeGroups: [["http", "https"]],
    declaresHTML: true)
workspace.candidates = [chrome, duplicate]
expect(launcher.options().count == 1,
       "duplicate bundle identifiers must collapse to one row")

let url = URL(string: "https://127.0.0.1:3080/?token=synthetic-test-only")!
SettingsManager.shared.preferredBrowserBundleIdentifier = nil
workspace.resolvable = ["com.example.chrome": chrome]
launcher.open(url)
expect(workspace.openedApps.isEmpty && workspace.openedDefaultURLs == [url],
       "system default must use plain open")

SettingsManager.shared.preferredBrowserBundleIdentifier = "com.example.chrome"
workspace.resolvable = ["com.example.chrome": chrome]
launcher.open(url)
expect(workspace.openedApps.count == 1 && workspace.openedApps[0].app == chrome,
       "chosen browser not used")
expect(workspace.openedApps[0].url == url, "chosen browser received the wrong URL")

// A stored identifier whose application is gone must not break Open Web.
SettingsManager.shared.preferredBrowserBundleIdentifier = "com.example.gone"
launcher.open(url)
expect(workspace.openedDefaultURLs.last == url,
       "vanished browser must fall back to system default")

// A terminal that claims http/https is not a browser, even when chosen.
SettingsManager.shared.preferredBrowserBundleIdentifier = "com.example.terminal"
workspace.resolvable = ["com.example.terminal": terminal]
launcher.open(url)
expect(workspace.openedDefaultURLs.last == url,
       "client app must not receive Web console links")
expect(workspace.openedApps.count == 1, "client app must not receive Web console links")

workspace.defaultApplication = nil
expect(launcher.systemDefaultBrowserName() == nil,
       "missing default handler must not crash or invent a name")
print("PASS browser detection filters terminals and honours the chosen browser")
'''


def main() -> None:
    launcher_source = (ROOT / "Sources/BrowserLauncher.swift").read_text()
    candidate = method(launcher_source, "struct BrowserCandidate")
    browser_launcher = method(launcher_source, "final class BrowserLauncher")
    program = STUBS + "\n" + candidate + "\n\n" + browser_launcher + "\n" + CHECKS

    with tempfile.TemporaryDirectory(prefix="dshbar-browser-picker-") as directory:
        scratch = Path(directory)
        source, binary = scratch / "main.swift", scratch / "browser-picker"
        source.write_text(program)
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(scratch / "modulecache"))
        subprocess.run(["xcrun", "swiftc", "-Onone", str(source), "-o", str(binary)],
                       env=env, check=True, timeout=120)
        subprocess.run([str(binary), str(scratch)], env=env, check=True, timeout=30)

    setting = (ROOT / "Sources/SettingsManager.swift").read_text()
    assert setting.count('"DSH_PreferredBrowser"') == 1, "the preference key literal must appear once"
    assert "string(forKey: preferredBrowserKey)" in setting, "getter must use the key constant"
    assert "set(newValue, forKey: preferredBrowserKey)" in setting, "setter must use the key constant"
    assert "removeObject(forKey: preferredBrowserKey)" in setting, "clearing must use the key constant"
    print("PASS preferred browser is stored through one key constant")

    service = (ROOT / "Sources/ServiceManager.swift").read_text()
    open_browser = method(service, "func openBrowser()")
    assert open_browser.count("BrowserLauncher.shared.open(") == 2, \
        "both Open Web paths must go through BrowserLauncher"
    assert "NSWorkspace.shared.open" not in open_browser, \
        "Open Web must not open the URL itself"
    print("PASS Open Web routes both paths through BrowserLauncher")

    assert "Sources/BrowserLauncher.swift" in (ROOT / "build.sh").read_text(), \
        "build.sh must compile Sources/BrowserLauncher.swift"
    print("PASS build.sh compiles the browser launcher")


if __name__ == "__main__":
    main()
