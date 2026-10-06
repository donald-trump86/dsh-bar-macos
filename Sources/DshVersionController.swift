import Foundation

/// One entry in the install-channel popup: an npm dist-tag, the version it
/// currently resolves to, and whether that version is the one already on disk.
struct TagOption: Equatable {
    let tag: String
    let version: String
    let isInstalled: Bool
}

/// Why a dist-tag probe could not produce a list.
///
/// `Error` is required by the declared `fetchTags` signature, which hands this
/// out as a `Result` failure.
enum ProbeFailure: Equatable, Error {
    case offline, timedOut, notFound, badResponse

    /// Drives the row's description label. The failure reason is what the user
    /// sees instead of a dropdown: an empty list with no explanation reads as a
    /// broken app, not an unreachable network.
    var message: String {
        switch self {
        case .offline:    return L(.tagProbeOffline)
        case .timedOut:   return L(.tagProbeTimedOut)
        case .notFound:   return L(.tagProbeNotFound)
        case .badResponse: return L(.tagProbeBadResponse)
        }
    }
}

/// What the install-channel row knows about the registry right now.
///
/// The row renders from this alone, so every "what should the controls do"
/// question is answered by a value rather than by view code reacting to events.
enum ProbeState {
    case idle
    case loading
    case loaded(tags: [String: String], installedVersion: String?)
    case failed(ProbeFailure)

    var tags: [String: String] {
        if case .loaded(let tags, _) = self { return tags }
        return [:]
    }

    var installedVersion: String? {
        if case .loaded(_, let version) = self { return version }
        return nil
    }

    var failure: ProbeFailure? {
        if case .failed(let reason) = self { return reason }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// The popup's items, newest channel first.
    ///
    /// Two tags pointing at the same version are both marked installed, and
    /// both stay separately selectable — the user's choice is "follow latest" vs
    /// "follow next", and today those happen to resolve alike. Marking by
    /// version instead would collapse the distinction the moment the tags
    /// diverge.
    func options() -> [TagOption] {
        guard case .loaded(let tags, let installed) = self else { return [] }
        return tags
            .map { TagOption(tag: $0.key, version: $0.value, isInstalled: $0.value == installed) }
            .sorted { lhs, rhs in
                if lhs.isInstalled != rhs.isInstalled { return lhs.isInstalled }
                return lhs.tag < rhs.tag
            }
    }

    /// The installed tag, if any. An install is only worth offering when it
    /// moves a different channel than the one already on disk.
    var installedTag: String? {
        options().first { $0.isInstalled }?.tag
    }
}

/// Everything that can go wrong between choosing a tag and npm finishing.
enum DshVersionControllerError: LocalizedError {
    case invalidTag(String)
    case alreadyInstalling
    case npmNotFound
    case installFailed(exitCode: Int32, output: String)
    case installCouldNotStart(String)

    var errorDescription: String? {
        switch self {
        case .invalidTag(let tag):
            return L(.installTagInvalid, ["tag": tag])
        case .alreadyInstalling:
            return L(.installAlreadyRunning)
        case .installFailed(let exitCode, let output):
            // npm's own stderr is the useful part — EACCES from a root-owned
            // prefix is the common failure and the app cannot fix it.
            let detail = output.isEmpty ? L(.installNoOutput) : output
            return L(.installFailedBody, ["code": "\(exitCode)", "output": detail])
        case .npmNotFound:
            return L(.installNpmNotFound)
        case .installCouldNotStart(let message):
            return L(.installCouldNotStart, ["reason": message])
        }
    }
}

/// Owns every fact about npm tag semantics: the registry endpoint, how a tag
/// becomes a command, and which tag the machine is already on.
///
/// It knows nothing about AppKit. The preferences row reads `ProbeState` and
/// calls `install(tag:completion:)`; it never parses a URL or builds a command
/// of its own.
final class DshVersionController {
    static let shared = DshVersionController()

    /// The dist-tags document only — never the full packument, which is ~200KB
    /// and answers a question this row does not ask.
    private static let distTagsURL = URL(
        string: "https://registry.npmjs.org/-/package/@deepseek-ai/dsh/dist-tags"
    )!
    private static let probeTimeout: TimeInterval = 5.0

    /// A tag the registry can legally return: letters, digits, `-`, `.`, `_`.
    ///
    /// This is an allowlist, not a denylist. The tag is attacker-shaped input
    /// that reaches a popup label, a stored preference, and a command — so it
    /// is refused outright rather than sanitised into something the user then
    /// approves without knowing it changed.
    static func validTag(_ tag: String) -> Bool {
        !tag.isEmpty
            && tag.range(of: "^[a-zA-Z0-9-._]+$", options: .regularExpression) != nil
    }

    /// The command shown in the confirmation dialog and executed on confirm.
    ///
    /// Returns nil rather than sanitising: a tag we cannot vouch for must never
    /// become a command the user is asked to approve, because they approve it
    /// without knowing what it was rewritten to.
    static func installCommand(forTag tag: String) -> String? {
        guard validTag(tag) else { return nil }
        return "\(ServiceManager.installCommand)@\(tag)"
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5.0
        config.timeoutIntervalForResource = 5.0
        return URLSession(configuration: config)
    }()

    private var installInFlight = false

    /// Whether an npm process is running right now. The row reads this to grey
    /// out its own button; `install` refuses a second run regardless.
    private(set) var isInstalling = false

    func fetchTags(completion: @escaping (Result<[String: String], ProbeFailure>) -> Void) {
        var request = URLRequest(url: Self.distTagsURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.probeTimeout
        session.dataTask(with: request) { data, response, error in
            if let error = error as? URLError {
                let failure: ProbeFailure = error.code == .timedOut ? .timedOut : .offline
                return DispatchQueue.main.async { completion(.failure(failure)) }
            }
            guard let http = response as? HTTPURLResponse else {
                return DispatchQueue.main.async { completion(.failure(.badResponse)) }
            }
            guard http.statusCode == 200 else {
                let failure: ProbeFailure = http.statusCode == 404 ? .notFound : .badResponse
                return DispatchQueue.main.async { completion(.failure(failure)) }
            }
            guard let data,
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  !parsed.isEmpty
            else {
                return DispatchQueue.main.async { completion(.failure(.badResponse)) }
            }
            DispatchQueue.main.async { completion(.success(parsed)) }
        }.resume()
    }

    /// Runs npm for one tag. Never a shell: argv is `executableURL` plus
    /// `arguments`, so a tag cannot become shell syntax even if the allowlist
    /// above is ever loosened.
    func install(tag: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let command = Self.installCommand(forTag: tag) else {
            return DispatchQueue.main.async {
                completion(.failure(DshVersionControllerError.invalidTag(tag)))
            }
        }
        // A second install is dropped, not queued: two `npm install -g` runs
        // against the same global prefix corrupt each other.
        guard !installInFlight else {
            return DispatchQueue.main.async {
                completion(.failure(DshVersionControllerError.alreadyInstalling))
            }
        }
        guard let npm = ServiceManager.shared.findNpmBinary() else {
            return DispatchQueue.main.async {
                completion(.failure(DshVersionControllerError.npmNotFound))
            }
        }

        installInFlight = true
        isInstalling = true
        let arguments = command
            .split(separator: " ", omittingEmptySubsequences: true)
            .dropFirst()
            .map(String.init)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: npm)
        process.arguments = arguments
        process.environment = ServiceManager.commandEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        DispatchQueue.global(qos: .utility).async {
            defer {
                pipe.fileHandleForReading.closeFile()
                pipe.fileHandleForWriting.closeFile()
            }
            var failure: DshVersionControllerError?
            do {
                try process.run()
                // Only npm owns the write end now, so its exit produces EOF.
                pipe.fileHandleForWriting.closeFile()
                // Drain while npm runs: waiting first can fill the pipe and
                // block npm forever. Keep only the final 64 KiB of diagnostics.
                let outputLimit = 64 * 1024
                var output = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.readData(ofLength: 8192)
                    if chunk.isEmpty { break }
                    output.append(chunk)
                    if output.count > outputLimit {
                        output.removeFirst(output.count - outputLimit)
                    }
                }
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    failure = .installFailed(
                        exitCode: process.terminationStatus,
                        output: String(decoding: output, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            } catch {
                failure = .installCouldNotStart(error.localizedDescription)
            }
            DispatchQueue.main.async {
                self.installInFlight = false
                self.isInstalling = false
                switch failure {
                case .some(let error):
                    completion(.failure(error))
                case .none:
                    completion(.success(""))
                }
            }
        }
    }
}