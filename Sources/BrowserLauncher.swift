import AppKit

/// A browser DSH Bar can hand the Web console URL to. Only the application
/// bundle is carried — the icon is fetched where it is shown.
struct BrowserCandidate: Equatable {
    let bundleIdentifier: String
    let displayName: String
    let applicationURL: URL
}

/// Decides which browser `Open Web` uses.
///
/// Detection reads LaunchServices once per panel build. The filter is
/// deliberately structural rather than category-based: `LSApplicationCategoryType`
/// is absent on Chrome/Brave/Orion and says "productivity" for Safari, Firefox,
/// Zen and iTerm alike, and iTerm also declares http/https plus `public.html`.
/// Scheme groups and HTML handling are what actually separate a browser from a
/// terminal.
final class BrowserLauncher {
    static let shared = BrowserLauncher()

    static let sampleURL = URL(string: "https://example.com")!

    /// Applications that claim http/https because they *open links in another
    /// program* (terminals, mail/news clients, file-transfer tools) rather than
    /// render pages. Observing iTerm's scheme list is what motivated this.
    private static let clientSchemes: Set<String> = [
        "ssh", "sftp", "telnet", "rlogin", "ftp", "tftp", "mailto", "news", "nntp",
        "gopher", "wais", "whois", "gemini", "titan", "irc", "ircs", "afp", "smb",
        "nfs", "x-man-page"
    ]

    private static let htmlExtensions: Set<String> = ["html", "htm", "shtml", "xhtml", "xht"]

    /// The installed applications that render pages, sorted by display name.
    /// Duplicates are kept to one entry per bundle identifier, which is what a
    /// picker row selects anyway.
    func options() -> [BrowserCandidate] {
        var seenIdentifiers: Set<String> = []
        var candidates: [BrowserCandidate] = []
        for applicationURL in NSWorkspace.shared.urlsForApplications(toOpen: Self.sampleURL) {
            guard let bundle = Bundle(url: applicationURL),
                  let identifier = bundle.bundleIdentifier,
                  Self.isBrowser(applicationURL),
                  seenIdentifiers.insert(identifier).inserted else { continue }
            candidates.append(BrowserCandidate(
                bundleIdentifier: identifier,
                displayName: Self.displayName(applicationURL),
                applicationURL: applicationURL
            ))
        }
        return candidates.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Display name of the handler the system would use for a Web console URL,
    /// or `nil` when nothing is registered for it.
    func systemDefaultBrowserName() -> String? {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: Self.sampleURL) else {
            return nil
        }
        return Self.displayName(applicationURL)
    }

    /// Opens `url` in the chosen browser, or in the system default when no
    /// choice was stored, when the stored application is gone, or when the
    /// stored application no longer qualifies as a browser.
    func open(_ url: URL) {
        if let identifier = SettingsManager.shared.preferredBrowserBundleIdentifier,
           let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
           Self.isBrowser(applicationURL) {
            NSWorkspace.shared.open([url], withApplicationAt: applicationURL,
                                    configuration: NSWorkspace.OpenConfiguration())
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Internals

    private static func schemes(_ applicationURL: URL) -> [[String]] {
        guard let bundle = Bundle(url: applicationURL),
              let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            return []
        }
        return types.compactMap { $0["CFBundleURLSchemes"] as? [String] }
    }

    private static func declaresHTML(_ applicationURL: URL) -> Bool {
        guard let bundle = Bundle(url: applicationURL),
              let types = bundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] else {
            return false
        }
        for type in types {
            if let contentTypes = type["LSItemContentTypes"] as? [String],
               contentTypes.contains("public.html") {
                return true
            }
            if let extensions = type["CFBundleTypeExtensions"] as? [String],
               extensions.contains(where: { htmlExtensions.contains($0.lowercased()) }) {
                return true
            }
        }
        return false
    }

    /// Reads the scheme groups as a union rather than per group because Firefox
    /// and Zen register `http`, `https` and `file` as three separate entries —
    /// requiring both web schemes inside one group would drop both browsers.
    private static func isBrowser(_ applicationURL: URL) -> Bool {
        let declared = Set(schemes(applicationURL).flatMap { $0.map { $0.lowercased() } })
        guard declared.contains("http"), declared.contains("https") else { return false }
        guard declared.isDisjoint(with: clientSchemes) else { return false }
        return declaresHTML(applicationURL)
    }

    private static func displayName(_ applicationURL: URL) -> String {
        applicationURL.deletingPathExtension().lastPathComponent
    }
}
