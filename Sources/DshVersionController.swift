import Foundation
import CryptoKit

/// Timing is independent of npm output and wall-clock adjustments.
struct InstallActivity: Equatable {
    enum Phase: Equatable { case resolving, downloading, verifying, installing, cancelling }
    let tag: String
    let startedAt: TimeInterval
    var phase: Phase = .resolving
    var bytesReceived: Int64 = 0
    var totalBytes: Int64? = nil
    var bytesPerSecond: Double = 0
    var outputTail: String = ""
    var version: String? = nil

    func elapsed(at now: TimeInterval) -> String {
        let seconds = max(0, Int(now - startedAt))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

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
    case cancelled

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
        case .cancelled:
            return L(.installCancelled)
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

    private(set) var installActivity: InstallActivity?
    private(set) var lastInstallLog: String = ""
    private(set) var isTerminating = false
    private var terminationWaiters: [() -> Void] = []
    var isInstalling: Bool { installActivity != nil }
    private var installer: ArchiveInstaller?
    private var activityTimer: Timer?
    private let fixtureOrigin: URL?
    private let temporaryRoot: URL
    private let stageObserver: ((InstallActivity.Phase) -> Void)?

    init(fixtureOrigin: URL? = nil, temporaryRoot: URL = FileManager.default.temporaryDirectory,
         stageObserver: ((InstallActivity.Phase) -> Void)? = nil) {
        // Test injection accepts loopback only; production never reads endpoint overrides.
        precondition(fixtureOrigin == nil || (fixtureOrigin?.scheme == "http"
            && fixtureOrigin?.host == "127.0.0.1" && fixtureOrigin?.user == nil
            && fixtureOrigin?.password == nil))
        self.fixtureOrigin = fixtureOrigin
        self.temporaryRoot = temporaryRoot
        self.stageObserver = stageObserver
    }

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

    /// Principal archive requests use the public registry; npm keeps its dependency environment.
    func install(tag: String, completion: @escaping (Result<String, Error>) -> Void) {
        if !Thread.isMainThread {
            return DispatchQueue.main.async { self.install(tag: tag, completion: completion) }
        }
        guard !isTerminating else {
            return DispatchQueue.main.async { completion(.failure(DshVersionControllerError.cancelled)) }
        }
        guard Self.validTag(tag) else {
            return DispatchQueue.main.async { completion(.failure(DshVersionControllerError.invalidTag(tag))) }
        }
        guard !isInstalling else {
            return DispatchQueue.main.async { completion(.failure(DshVersionControllerError.alreadyInstalling)) }
        }
        guard let npm = ServiceManager.shared.findNpmBinary() else {
            return DispatchQueue.main.async { completion(.failure(DshVersionControllerError.npmNotFound)) }
        }
        let worker = ArchiveInstaller(tag: tag, fixtureOrigin: fixtureOrigin,
                                      temporaryRoot: temporaryRoot, stageObserver: stageObserver)
        installer = worker
        lastInstallLog = ""
        installActivity = worker.snapshot()
        activityTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self, weak worker] _ in
            guard let self, let worker, self.installer === worker else { return }
            self.installActivity = worker.snapshot()
        }
        RunLoop.main.add(activityTimer!, forMode: .common)
        let environment = ServiceManager.commandEnvironment()
        DispatchQueue.global(qos: .utility).async {
            let result = worker.run(npm: npm, environment: environment)
            DispatchQueue.main.async {
                guard self.installer === worker else { return }
                self.activityTimer?.invalidate()
                self.activityTimer = nil
                self.lastInstallLog = worker.snapshot().outputTail
                self.installer = nil
                self.installActivity = nil
                completion(worker.isCancelled ? .failure(DshVersionControllerError.cancelled) : result)
                let waiters = self.terminationWaiters
                self.terminationWaiters.removeAll()
                waiters.forEach { $0() }
            }
        }
    }

    func cancelInstallForTermination(completion: @escaping () -> Void) {
        if !Thread.isMainThread {
            return DispatchQueue.main.async { self.cancelInstallForTermination(completion: completion) }
        }
        isTerminating = true
        guard installer != nil else { return DispatchQueue.main.async(execute: completion) }
        terminationWaiters.append(completion)
        cancelInstall()
    }

    func cancelInstall() {
        if !Thread.isMainThread { return DispatchQueue.main.async { self.cancelInstall() } }
        guard let installer else { return }
        installer.cancel()
        installActivity = installer.snapshot()
    }
}

/// One run owns its session, private archive, cancellation gate and bounded diagnostics.
private final class ArchiveInstaller: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private let cancellation = InstallCancellation()
    private var activity: InstallActivity
    private var tail = Data()
    private var sampleTime = ProcessInfo.processInfo.systemUptime
    private var sampleBytes: Int64 = 0
    private let fixtureOrigin: URL?
    private let temporaryRoot: URL
    private let stageObserver: ((InstallActivity.Phase) -> Void)?
    var isCancelled: Bool { cancellation.isCancelled }
    private var currentTask: URLSessionDataTask?
    private let finishedRequest = DispatchSemaphore(value: 0)
    // Delegate accesses these serially, then hands them to the waiting worker.
    private var responseData = Data()
    private var requestError: Error?
    private var archive: FileHandle?
    private var downloading = false
    private lazy var downloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 900
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    init(tag: String, fixtureOrigin: URL?, temporaryRoot: URL,
         stageObserver: ((InstallActivity.Phase) -> Void)?) {
        activity = InstallActivity(tag: tag, startedAt: ProcessInfo.processInfo.systemUptime)
        self.fixtureOrigin = fixtureOrigin
        self.temporaryRoot = temporaryRoot
        self.stageObserver = stageObserver
    }

    func cancel() {
        guard !cancellation.isCancelled else { return }
        cancellation.cancel()
        append(Data(("\n" + L(.installCancelled) + "\n").utf8))
        lock.lock()
        activity.phase = .cancelling
        activity.bytesPerSecond = 0
        let task = currentTask
        lock.unlock()
        task?.cancel()
    }

    func snapshot() -> InstallActivity {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if activity.phase == .downloading, now > sampleTime {
            activity.bytesPerSecond = Double(activity.bytesReceived - sampleBytes) / (now - sampleTime)
        } else {
            activity.bytesPerSecond = 0
        }
        sampleBytes = activity.bytesReceived
        sampleTime = now
        activity.outputTail = Self.logText(tail)
        return activity
    }

    private func phase(_ value: InstallActivity.Phase) throws {
        try cancellation.whileActive {
            lock.lock(); activity.phase = value; activity.bytesPerSecond = 0; lock.unlock()
        }
        stageObserver?(value)
        try cancellation.check()
    }

    private func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        tail.append(data)
        if tail.count > 65_536 { tail.removeFirst(tail.count - 65_536) }
    }

    private static func logText(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        // Best-effort display redaction; npm output is kept locally, without export here.
        for (pattern, replacement) in [
            (#"(https?://)[^\s/@]+(?::[^\s/@]*)?@"#, "$1[redacted]@"),
            (#"(?i)(authorization\s*[:=]\s*(?:bearer|basic)\s+)[^\s]+"#, "$1[redacted]"),
            (#"(?i)((?:_authToken|_auth|token|password)\s*[=:]\s*)[^\s&]+"#, "$1[redacted]")
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        while text.utf8.count > 65_536 { text.removeFirst() }
        return text
    }

    func run(npm: String, environment: [String: String]) -> Result<String, Error> {
        let directory = temporaryRoot.appendingPathComponent("dsh-install-" + UUID().uuidString, isDirectory: true)
        var result: Result<String, Error>
        var createdDirectory = false
        do {
            try cancellation.check()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            createdDirectory = true
            let archiveURL = directory.appendingPathComponent("package.tgz")
            append(Data("Resolving @deepseek-ai/dsh@\(activity.tag) from the public npm registry\n".utf8))
            let base = fixtureOrigin?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                ?? "https://registry.npmjs.org"
            let metadataURL = URL(string: base + "/@deepseek-ai%2fdsh/" + activity.tag)!
            let metadata = try request(metadataURL)
            guard let document = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
                  document["name"] as? String == "@deepseek-ai/dsh",
                  let version = document["version"] as? String,
                  version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#,
                                options: .regularExpression) != nil,
                  let dist = document["dist"] as? [String: Any],
                  let tarball = dist["tarball"] as? String, let url = URL(string: tarball), trusted(url),
                  url.path == "/@deepseek-ai/dsh/-/dsh-\(version).tgz",
                  let integrity = dist["integrity"] as? String,
                  let digest = integrity.split(separator: " ").compactMap({ token -> Data? in
                      guard token.hasPrefix("sha512-"),
                            let data = Data(base64Encoded: String(token.dropFirst(7))), data.count == 64 else { return nil }
                      return data
                  }).first else {
                throw failure("Invalid official package metadata, archive URL or SHA-512 integrity")
            }
            lock.lock(); activity.version = version; lock.unlock()
            try phase(.downloading)
            guard FileManager.default.createFile(atPath: archiveURL.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw failure("Could not create private package archive")
            }
            archive = try FileHandle(forWritingTo: archiveURL)
            _ = try request(url, download: true)
            try archive?.close()
            archive = nil
            try phase(.verifying)
            append(Data("Verifying SHA-512 for \(version)\n".utf8))
            let input = try FileHandle(forReadingFrom: archiveURL)
            do {
                defer { try? input.close() }
                var hash = SHA512()
                while true {
                    try cancellation.check()
                    let chunk = try input.read(upToCount: 128 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    hash.update(data: chunk)
                }
                guard Data(hash.finalize()) == digest else { throw failure("Package SHA-512 integrity mismatch") }
            }
            try phase(.installing)
            append(Data("Installing verified local archive with npm\n".utf8))
            let code = try InstallProcess.run(executable: npm,
                arguments: ["install", "-g", archiveURL.path, "--loglevel", "http"],
                environment: environment, cancellation: cancellation, output: append)
            try cancellation.check()
            if code != 0 {
                throw DshVersionControllerError.installFailed(exitCode: code,
                    output: snapshot().outputTail.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            append(Data("\nInstallation completed\n".utf8))
            result = .success("")
        } catch {
            let error: Error = cancellation.isCancelled ? DshVersionControllerError.cancelled
                : (error as? DshVersionControllerError ?? failure(error.localizedDescription))
            append(Data(("\n" + error.localizedDescription + "\n").utf8))
            result = .failure(error)
        }
        downloadSession.invalidateAndCancel()
        try? archive?.close()
        archive = nil
        do {
            if createdDirectory {
                try FileManager.default.removeItem(at: directory)
            }
        } catch {
            append(Data(("Archive cleanup failed: " + error.localizedDescription + "\n").utf8))
            if case .success = result { result = .failure(failure("Could not remove temporary package archive")) }
        }
        if cancellation.isCancelled { return .failure(DshVersionControllerError.cancelled) }
        return result
    }

    private func failure(_ detail: String) -> DshVersionControllerError { .installCouldNotStart(detail) }

    private func trusted(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        if let origin = fixtureOrigin {
            return url.scheme == "http" && url.host == "127.0.0.1" && url.port == origin.port
        }
        return url.scheme == "https" && url.host == "registry.npmjs.org" && (url.port == nil || url.port == 443)
    }

    private func request(_ url: URL, download: Bool = false) throws -> Data {
        try cancellation.check()
        responseData = Data()
        requestError = nil
        downloading = download
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = downloadSession.dataTask(with: request)
        lock.lock(); currentTask = task; lock.unlock()
        if cancellation.isCancelled { task.cancel() }
        task.resume()
        finishedRequest.wait()
        lock.lock(); currentTask = nil; lock.unlock()
        try cancellation.check()
        if let requestError { throw requestError }
        return responseData
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, trusted(url) else {
            requestError = failure("Refused a redirect outside the official package registry")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = response.url, trusted(url) else {
            if requestError == nil {
                requestError = failure("Package request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
            }
            completionHandler(.cancel)
            return
        }
        if downloading {
            lock.lock()
            activity.totalBytes = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            lock.unlock()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            if downloading {
                try archive?.write(contentsOf: data)
                lock.lock(); activity.bytesReceived += Int64(data.count); lock.unlock()
            } else {
                guard responseData.count + data.count <= 1024 * 1024 else {
                    throw failure("Package metadata exceeds the 1 MiB limit")
                }
                responseData.append(data)
            }
        } catch {
            requestError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if requestError == nil { requestError = error }
        finishedRequest.signal()
    }
}
