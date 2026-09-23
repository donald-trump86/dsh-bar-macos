import Foundation
import AppKit

enum ServicePhase: String, Equatable {
    case checking
    case stopped
    case starting
    case running
    case stopping
    case restarting
    case portConflict
    case error

    var isBusy: Bool {
        switch self {
        case .starting, .stopping, .restarting:
            return true
        default:
            return false
        }
    }
}

struct ServiceSnapshot: Equatable {
    var phase: ServicePhase
    var port: Int
    var pid: Int32?
    var startedAt: Date?
    var dshPath: String?
    var dshVersion: String?
    var message: String?
    var isManaged: Bool

    var isRunning: Bool { phase == .running }

    var uptime: TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, Date().timeIntervalSince(startedAt))
    }
}

final class ServiceManager {
    static let shared = ServiceManager()
    static let installCommand = "npm install -g @deepseek-ai/dsh"

    var port: Int { SettingsManager.shared.port }

    var baseUrl: URL {
        let activePort = snapshot.isRunning ? snapshot.port : port
        return URL(string: "http://127.0.0.1:\(activePort)")!
    }

    private(set) var snapshot: ServiceSnapshot
    private(set) var dshDetectionComplete = false
    var isRunning: Bool { snapshot.isRunning }

    private var statusObservers: [UUID: (ServiceSnapshot) -> Void] = [:]
    private var portObserverToken: UUID?
    private var timer: Timer?
    private var checkInFlight = false
    private var pendingCheckCompletions: [(Bool) -> Void] = []
    private var consecutiveProbeMisses = 0
    private let session: URLSession
    private var launchedProcess: Process?
    private var launchedLogHandle: FileHandle?
    private var authenticatedURL: URL?
    private var managedRecord: ManagedServiceRecord?

    // MARK: - Reliability state
    //
    // A managed service can disappear for two very different reasons: the user
    // asked us to stop it, or it died on its own. Anything that reacts to the
    // loss (notifications, auto-restart) must be able to tell them apart, and
    // the second case must keep enough identity to know the service was ours.

    /// Set while a stop/restart this app initiated is in flight, so the listener
    /// going away is not mistaken for a crash.
    private var intentionalStopInFlight = false
    /// When the last *managed* run ended without us asking. Surfaced in the UI.
    private(set) var lastUnexpectedExit: Date?
    private(set) var lastUnexpectedExitPID: Int32?
    /// Set once the recovery budget for the current window is spent. Kept until
    /// the user acts, because `snapshot.message` is wiped by the next probe.
    private(set) var recoverySuspended = false
    /// Timestamps of automatic restarts already attempted, for the rate limit.
    private var autoRestartAttempts: [Date] = []
    private var autoRestartWorkItem: DispatchWorkItem?
    /// Attempts allowed inside `autoRestartWindow`, with backoff between them.
    static let autoRestartMaxAttempts = 3
    static let autoRestartWindow: TimeInterval = 600
    static let autoRestartBackoff: [TimeInterval] = [1, 4, 16]
    /// User-facing switch for crash recovery.
    var autoRestartEnabled: Bool {
        get { SettingsManager.shared.autoRestartEnabled }
        set { SettingsManager.shared.autoRestartEnabled = newValue }
    }

    private enum ProbeResult {
        case harness(pid: Int32?, startedAt: Date?)
        case foreign(pid: Int32?)
        case unavailable

        var isHarness: Bool {
            if case .harness = self { return true }
            return false
        }
    }

    private enum StopResult {
        case stopped
        case foreign
        case none
        case failed(String)
    }

    /// Everything that must be true *before* an existing service is stopped.
    ///
    /// Both restart paths run this first, because a check that fails after the
    /// stop leaves the user worse off than before they clicked: the working
    /// service is gone and the replacement never starts. Returns a reason when
    /// the restart must be refused, or `nil` when it is safe to proceed.
    private func preflightRestart(currentPort: Int, targetPort: Int) -> String? {
        if targetPort != currentPort {
            guard case .unavailable = probe(port: targetPort) else {
                return L(.portBusyLeftRunning, ["port": "\(targetPort)", "current": "\(currentPort)"])
            }
        }
        guard findDshBinary() != nil else {
            // The likeliest cause is an uninstalled or shadowed CLI (for example
            // after switching Node versions with nvm/fnm). Refuse rather than
            // tear down a service we would not be able to bring back.
            return L(.dshMissingLeftAlone, ["command": Self.installCommand])
        }
        return nil
    }

    private struct ManagedServiceRecord: Codable {
        let pid: Int32
        let port: Int
        let startedAt: Date
        let executablePath: String
    }

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.0
        config.timeoutIntervalForResource = 1.0
        session = URLSession(configuration: config)
        let restoredRecord = Self.loadManagedRecord()
        managedRecord = restoredRecord
        snapshot = ServiceSnapshot(
            phase: .checking,
            port: restoredRecord?.port ?? SettingsManager.shared.port,
            pid: restoredRecord?.pid,
            startedAt: restoredRecord?.startedAt,
            dshPath: nil,
            dshVersion: nil,
            message: nil,
            isManaged: false
        )

        portObserverToken = SettingsManager.shared.addPortObserver { [weak self] newPort in
            guard let self else { return }
            if self.snapshot.phase.isBusy {
                self.updateSnapshot {
                    $0.message = L(.portChangedAppliesLater, ["port": "\(newPort)"])
                }
            } else if self.snapshot.isRunning {
                // Keep the actual running port until the user restarts. Otherwise
                // changing the configured port would orphan the old listener.
                self.updateSnapshot {
                    $0.message = newPort == $0.port
                        ? nil
                        : L(.portChangedRestartToApply, ["port": "\(newPort)"])
                }
            } else {
                self.updateSnapshot {
                    $0.port = newPort
                    $0.phase = .checking
                    $0.pid = nil
                    $0.startedAt = nil
                    $0.message = nil
                }
                self.checkStatus()
            }
        }
    }

    @discardableResult
    func addStatusObserver(_ observer: @escaping (ServiceSnapshot) -> Void) -> UUID {
        let token = UUID()
        statusObservers[token] = observer
        observer(snapshot)
        return token
    }

    func removeStatusObserver(_ token: UUID) {
        statusObservers.removeValue(forKey: token)
    }

    private func updateSnapshot(_ mutation: (inout ServiceSnapshot) -> Void) {
        precondition(Thread.isMainThread)
        mutation(&snapshot)
        for observer in Array(statusObservers.values) {
            observer(snapshot)
        }
    }

    func startMonitoring(interval: TimeInterval = 2.0) {
        detectDshInstallation()
        checkStatus()
        timer?.invalidate()
        let monitorTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkStatus()
        }
        timer = monitorTimer
        RunLoop.main.add(monitorTimer, forMode: .common)
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - DSH Installation

    func detectDshInstallation(completion: ((Bool) -> Void)? = nil) {
        dshDetectionComplete = false
        updateSnapshot { _ in }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let path = self.findDshBinary()
            let version = path.flatMap { self.readDshVersion(at: $0) }
            DispatchQueue.main.async {
                self.dshDetectionComplete = true
                self.updateSnapshot {
                    $0.dshPath = path
                    $0.dshVersion = version
                }
                completion?(path != nil)
            }
        }
    }

    func findDshBinary() -> String? {
        findExecutable(named: "dsh")
    }

    func findNpmBinary() -> String? {
        findExecutable(named: "npm")
    }

    private func findExecutable(named name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.environment = Self.commandEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    private func readDshVersion(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = Self.commandEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.split(separator: "\n").first.map(String.init)
    }

    private static func commandEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let preferredPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let inheritedPath = environment["PATH"] ?? ""
        environment["PATH"] = (preferredPaths + [inheritedPath])
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        return environment
    }

    // MARK: - Status Monitoring

    private static let harnessMarkers = ["dsh web", "__dsh_boot__", "deepseek harness"]

    func checkStatus(completion: ((Bool) -> Void)? = nil) {
        if let completion {
            pendingCheckCompletions.append(completion)
        }
        guard !checkInFlight else { return }
        checkInFlight = true
        let checkedPort = snapshot.isRunning ? snapshot.port : (managedRecord?.port ?? port)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = self.probe(port: checkedPort)
            DispatchQueue.main.async {
                self.checkInFlight = false
                let expectedPort = self.snapshot.isRunning
                    ? self.snapshot.port
                    : (self.managedRecord?.port ?? self.port)
                if !self.snapshot.phase.isBusy, expectedPort == checkedPort {
                    self.applyProbe(result, port: checkedPort)
                }
                let completions = self.pendingCheckCompletions
                self.pendingCheckCompletions.removeAll()
                completions.forEach { $0(result.isHarness) }
            }
        }
    }

    private func probe(port: Int) -> ProbeResult {
        guard let url = URL(string: "http://127.0.0.1:\(port)") else {
            return .unavailable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 1.0

        // URLSession delivers its callback on a delegate queue, so both the
        // timeout path and the callback path race on this box. A lock keeps the
        // read/write ordered, and the task is cancelled if the wait expires.
        let box = HTTPProbeBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, _ in
            box.store(data: data, response: response as? HTTPURLResponse)
            semaphore.signal()
        }
        task.resume()
        let finished = semaphore.wait(timeout: .now() + 1.5) == .success
        if !finished {
            task.cancel()
        }

        let listenerPID = listenerPID(on: port)
        let outcome = box.snapshot()
        if let httpResponse = outcome.response {
            let body = String(data: outcome.data ?? Data(), encoding: .utf8)?.lowercased() ?? ""
            let reachable = (200...599).contains(httpResponse.statusCode)
            if reachable, Self.harnessMarkers.contains(where: body.contains) {
                return .harness(pid: listenerPID, startedAt: listenerPID.flatMap(processStartDate))
            }
            return .foreign(pid: listenerPID)
        }

        if listenerPID != nil {
            return .foreign(pid: listenerPID)
        }
        return .unavailable
    }

    private func applyProbe(_ result: ProbeResult, port: Int) {
        switch result {
        case let .harness(pid, startedAt):
            consecutiveProbeMisses = 0
            let previousPID = snapshot.pid
            var isManaged = false
            // Only ever discard the record on *conclusive* evidence that the
            // listener is not ours. `startedAt` comes from `ps`, which can fail
            // transiently; treating that as "not ours" would silently demote a
            // healthy managed service to external and erase its identity. The
            // destructive paths re-verify independently anyway, so being
            // conservative here costs nothing.
            if let record = managedRecord, record.port == port {
                if record.pid == pid {
                    if let startedAt, abs(startedAt.timeIntervalSince(record.startedAt)) >= 5 {
                        // Measured start time disagrees: the PID was reused.
                        clearManagedRecord()
                    } else {
                        isManaged = true
                    }
                } else {
                    clearManagedRecord()
                }
            }
            if previousPID != pid {
                authenticatedURL = nil
            }
            updateSnapshot {
                $0.phase = .running
                $0.port = port
                $0.pid = pid
                $0.startedAt = startedAt ?? $0.startedAt
                $0.message = isManaged ? nil : L(.externalService)
                $0.isManaged = isManaged
            }
        case let .foreign(pid):
            consecutiveProbeMisses = 0
            authenticatedURL = nil
            if managedRecord?.port == port {
                clearManagedRecord()
            }
            updateSnapshot {
                $0.phase = .portConflict
                $0.port = port
                $0.pid = pid
                $0.startedAt = nil
                $0.message = pid.map { L(.portUsedByPID, ["port": "\(port)", "pid": "\($0)"]) }
                    ?? L(.portAlreadyInUse, ["port": "\(port)"])
                $0.isManaged = false
            }
        case .unavailable:
            if snapshot.isRunning, consecutiveProbeMisses < 1 {
                consecutiveProbeMisses += 1
                return
            }
            consecutiveProbeMisses = 0
            authenticatedURL = nil
            // Decide *before* the identity is dropped whether this disappearance
            // was ours to expect. Only an unrequested loss of a service we
            // started counts as a crash.
            let ownedByUs = managedRecord?.port == port
            let wasIntentional = intentionalStopInFlight
            let lostPID = snapshot.pid
            if ownedByUs {
                clearManagedRecord()
            }
            updateSnapshot {
                $0.phase = .stopped
                $0.port = SettingsManager.shared.port
                $0.pid = nil
                $0.startedAt = nil
                $0.message = nil
                $0.isManaged = false
            }
            if ownedByUs, !wasIntentional {
                handleUnexpectedExit(pid: lostPID, port: port)
            }
        }
    }

    private func listenerPID(on port: Int) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-tiTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return output.split(whereSeparator: \.isNewline).first.flatMap { Int32($0) }
    }

    private func processStartDate(pid: Int32) -> Date? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "etime="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let elapsed = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let seconds = parseElapsedTime(elapsed) else { return nil }
        return Date().addingTimeInterval(-seconds)
    }

    private func parseElapsedTime(_ value: String) -> TimeInterval? {
        guard !value.isEmpty else { return nil }
        let dayParts = value.split(separator: "-", maxSplits: 1).map(String.init)
        let days: Int
        let timePart: String
        if dayParts.count == 2 {
            days = Int(dayParts[0]) ?? 0
            timePart = dayParts[1]
        } else {
            days = 0
            timePart = dayParts[0]
        }

        let components = timePart.split(separator: ":").compactMap { Int($0) }
        guard components.count == 2 || components.count == 3 else { return nil }
        let hours = components.count == 3 ? components[0] : 0
        let minutes = components.count == 3 ? components[1] : components[0]
        let seconds = components.count == 3 ? components[2] : components[1]
        return TimeInterval(days * 86_400 + hours * 3_600 + minutes * 60 + seconds)
    }

    // MARK: - Files

    private static var dshDirectoryURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dsh")
    }

    private static var managedRecordURL: URL {
        dshDirectoryURL.appendingPathComponent("dsh-bar-service.json")
    }

    private static func loadManagedRecord() -> ManagedServiceRecord? {
        guard let data = try? Data(contentsOf: managedRecordURL) else { return nil }
        return try? JSONDecoder().decode(ManagedServiceRecord.self, from: data)
    }

    private func saveManagedRecord(_ record: ManagedServiceRecord) {
        let directory = Self.dshDirectoryURL
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: Self.managedRecordURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: Self.managedRecordURL.path
            )
        }
        managedRecord = record
    }

    private func clearManagedRecord() {
        managedRecord = nil
        try? FileManager.default.removeItem(at: Self.managedRecordURL)
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    var logDirectory: URL {
        let directory = Self.dshDirectoryURL.appendingPathComponent("logs")
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    var logFileURL: URL {
        logDirectory.appendingPathComponent("dsh-web.log")
    }

    var pidFileURL: URL {
        let directory = Self.dshDirectoryURL
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory.appendingPathComponent("dsh-web.pid")
    }

    // MARK: - Service Lifecycle

    func startService(completion: @escaping (Bool, String?) -> Void) {
        beginLaunch(acknowledgeCrash: true, completion: completion)
    }

    /// Shared launch entry point.
    ///
    /// `acknowledgeCrash` separates the two callers that matter: a person
    /// clicking Start has seen the notice, whereas a recovery restart has not —
    /// and must not erase the only evidence that the service ever died. That
    /// matters most exactly when notifications are unavailable, which is the
    /// normal case for an ad-hoc signed build.
    private func beginLaunch(acknowledgeCrash: Bool, completion: @escaping (Bool, String?) -> Void) {
        guard !snapshot.phase.isBusy else {
            completion(false, L(.opInProgress))
            return
        }
        if acknowledgeCrash {
            // The first start is the moment notifications become relevant, so
            // that is when macOS is asked — not on launch, and not every time.
            ServiceNotifier.shared.requestAuthorizationIfNeeded()
            acknowledgeUnexpectedExit()
        }
        authenticatedURL = nil
        updateSnapshot {
            $0.phase = .starting
            $0.message = nil
        }
        launchAndWait(completion: completion)
    }

    /// Describes a crash that is still unacknowledged, so the UI can show it
    /// after an automatic recovery has already made the service look healthy.
    var recoveryNotice: String? {
        if recoverySuspended {
            return L(.recoveryPaused)
        }
        guard let when = lastUnexpectedExit else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return L(.recoveredAfterExit, ["time": formatter.string(from: when)])
    }

    /// Clears the crash notice once the user has acted on it. Starting the
    /// service again also resets the recovery budget.
    func acknowledgeUnexpectedExit() {
        recoverySuspended = false
        guard lastUnexpectedExit != nil else { return }
        lastUnexpectedExit = nil
        lastUnexpectedExitPID = nil
    }

    func stopService(completion: @escaping (Bool, String?) -> Void) {
        guard !snapshot.phase.isBusy else {
            completion(false, L(.opInProgress))
            return
        }
        guard snapshot.isManaged else {
            completion(false, L(.notStartedByUsWontStop))
            return
        }
        let currentPort = snapshot.port
        // The user is taking control: a disappearance from here on is expected,
        // a recovery that was already queued must not fire underneath them, and
        // the previous crash notice has been seen.
        cancelPendingAutoRestart()
        acknowledgeUnexpectedExit()
        beginIntentionalStop()
        updateSnapshot {
            $0.phase = .stopping
            $0.message = nil
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runStopScript(port: currentPort)
            Thread.sleep(forTimeInterval: 0.35)
            let probe = self.probe(port: currentPort)
            DispatchQueue.main.async {
                self.endIntentionalStop()
                self.finishStop(result: result, probe: probe, port: currentPort, completion: completion)
            }
        }
    }

    func restartService(completion: @escaping (Bool, String?) -> Void) {
        guard !snapshot.phase.isBusy else {
            completion(false, L(.opInProgress))
            return
        }
        guard snapshot.isManaged else {
            completion(false, L(.notStartedByUsCannotRestart))
            return
        }
        let previousSnapshot = snapshot
        let previousAuthenticatedURL = authenticatedURL
        let currentPort = snapshot.isRunning ? snapshot.port : port
        let targetPort = port
        cancelPendingAutoRestart()
        authenticatedURL = nil
        // Everything from here until `finish` runs is our own doing, so a
        // listener that goes missing mid-restart is never a crash.
        beginIntentionalStop()
        let finish: (Bool, String?) -> Void = { [weak self] success, message in
            self?.endIntentionalStop()
            completion(success, message)
        }
        updateSnapshot {
            $0.phase = .restarting
            $0.message = nil
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if let reason = self.preflightRestart(currentPort: currentPort, targetPort: targetPort) {
                DispatchQueue.main.async {
                    self.authenticatedURL = previousAuthenticatedURL
                    self.updateSnapshot {
                        $0 = previousSnapshot
                        $0.message = reason
                    }
                    finish(false, reason)
                }
                return
            }

            let stopResult = self.runStopScript(port: currentPort)
            if case let .failed(reason) = stopResult {
                DispatchQueue.main.async {
                    let message = reason.isEmpty ? L(.failedToStopExisting) : reason
                    self.authenticatedURL = previousAuthenticatedURL
                    self.updateSnapshot {
                        $0 = previousSnapshot
                        $0.message = message
                    }
                    finish(false, message)
                }
                return
            }
            if case .foreign = stopResult {
                DispatchQueue.main.async {
                    let message = L(.listenerNoLongerMatches, ["port": "\(currentPort)"])
                    self.clearManagedRecord()
                    self.updateSnapshot {
                        $0.phase = .portConflict
                        $0.message = message
                        $0.isManaged = false
                    }
                    finish(false, message)
                }
                return
            }

            Thread.sleep(forTimeInterval: 0.6)
            let stoppedProbe = self.probe(port: currentPort)
            guard case .unavailable = stoppedProbe else {
                DispatchQueue.main.async {
                    let message = L(.oldStillListening, ["port": "\(currentPort)"])
                    self.authenticatedURL = previousAuthenticatedURL
                    self.updateSnapshot {
                        $0 = previousSnapshot
                        $0.message = message
                    }
                    finish(false, message)
                }
                return
            }

            DispatchQueue.main.async {
                self.clearManagedRecord()
                self.launchAndWait(completion: finish)
            }
        }
    }

    // MARK: - Services started outside DSH Bar

    /// Details shown before an external service is touched. The user has to see
    /// exactly which process is about to be terminated, so the command line is
    /// resolved on request rather than guessed from the port.
    struct ExternalServiceInfo {
        let pid: Int32
        let port: Int
        let command: String
    }

    var hasUnmanagedService: Bool {
        snapshot.isRunning && !snapshot.isManaged
    }

    func describeUnmanagedService(completion: @escaping (ExternalServiceInfo?) -> Void) {
        let current = snapshot
        guard current.isRunning, !current.isManaged, let pid = current.pid else {
            completion(nil)
            return
        }
        let activePort = current.port
        DispatchQueue.global(qos: .userInitiated).async {
            let command = Self.commandLine(for: pid)
            DispatchQueue.main.async {
                completion(
                    ExternalServiceInfo(
                        pid: pid,
                        port: activePort,
                        command: command ?? L(.pidLabel, ["pid": "\(pid)"])
                    )
                )
            }
        }
    }

    /// Terminates a service the user confirmed, even though DSH Bar did not
    /// start it. The request always carries an explicit PID, and the script
    /// re-verifies that this PID is the *only* listener on the port and that it
    /// really answers as DeepSeek Harness before signalling it.
    func stopUnmanagedService(pid: Int32, completion: @escaping (Bool, String?) -> Void) {
        guard !snapshot.phase.isBusy else {
            completion(false, L(.opInProgress))
            return
        }
        guard snapshot.isRunning, !snapshot.isManaged else {
            completion(false, unmanagedRefusalReason())
            return
        }
        guard snapshot.pid == pid else {
            completion(false, L(.notTheServiceAnymore))
            return
        }
        let currentPort = snapshot.port
        cancelPendingAutoRestart()
        beginIntentionalStop()
        updateSnapshot {
            $0.phase = .stopping
            $0.message = nil
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = self.runExternalStopScript(port: currentPort, pid: pid)
            Thread.sleep(forTimeInterval: 0.35)
            let probe = self.probe(port: currentPort)
            DispatchQueue.main.async {
                self.finishUnmanagedStop(
                    outcome: outcome,
                    probe: probe,
                    port: currentPort,
                    completion: completion
                )
            }
        }
    }

    /// Stops the externally started service and relaunches it under DSH Bar's
    /// management, so later Stop/Restart work without any terminal round trip.
    func restartUnmanagedService(pid: Int32, completion: @escaping (Bool, String?) -> Void) {
        guard !snapshot.phase.isBusy else {
            completion(false, L(.opInProgress))
            return
        }
        guard snapshot.isRunning, !snapshot.isManaged else {
            completion(false, unmanagedRefusalReason())
            return
        }
        guard snapshot.pid == pid else {
            completion(false, L(.notTheServiceAnymore))
            return
        }
        let currentPort = snapshot.port
        let targetPort = port
        let previousSnapshot = snapshot
        authenticatedURL = nil
        updateSnapshot {
            $0.phase = .restarting
            $0.message = nil
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // Refuse BEFORE touching the external service: it is not ours to
            // kill if we cannot put an equivalent one back in its place.
            if let reason = self.preflightRestart(currentPort: currentPort, targetPort: targetPort) {
                DispatchQueue.main.async {
                    self.updateSnapshot {
                        $0 = previousSnapshot
                        $0.message = reason
                        $0.isManaged = false
                    }
                    completion(false, reason)
                }
                return
            }

            let outcome = self.runExternalStopScript(port: currentPort, pid: pid)
            guard case .stopped = outcome else {
                DispatchQueue.main.async {
                    self.finishUnmanagedStop(
                        outcome: outcome,
                        probe: self.probe(port: currentPort),
                        port: currentPort,
                        completion: completion
                    )
                }
                return
            }

            Thread.sleep(forTimeInterval: 0.6)
            guard case .unavailable = self.probe(port: currentPort) else {
                DispatchQueue.main.async {
                    let message = L(.externalStillListening, ["port": "\(currentPort)"])
                    self.updateSnapshot {
                        $0.phase = .portConflict
                        $0.message = message
                        $0.isManaged = false
                    }
                    completion(false, message)
                }
                return
            }

            DispatchQueue.main.async {
                self.launchAndWait(completion: completion)
            }
        }
    }

    private enum ExternalStopOutcome {
        case stopped
        case refused(String)
    }

    /// Explains why an external stop/restart request was rejected, so the alert
    /// names the real condition instead of a generic failure.
    private func unmanagedRefusalReason() -> String {
        switch snapshot.phase {
        case .portConflict:
            return L(.portHeldNotHarness, ["port": "\(snapshot.port)"])
        case .running:
            return L(.startedByUsUseNormal)
        default:
            return L(.nothingToStop)
        }
    }

    private func finishUnmanagedStop(
        outcome: ExternalStopOutcome,
        probe: ProbeResult,
        port: Int,
        completion: @escaping (Bool, String?) -> Void
    ) {
        switch outcome {
        case let .refused(reason):
            updateSnapshot {
                $0.phase = .running
                $0.message = reason
                $0.isManaged = false
            }
            completion(false, reason)
        case .stopped:
            if case .harness = probe {
                let message = L(.terminatedButStillServing, ["port": "\(port)"])
                updateSnapshot {
                    $0.phase = .portConflict
                    $0.message = message
                    $0.isManaged = false
                }
                completion(false, message)
                return
            }
            if case let .foreign(pid) = probe {
                let message = pid.map { L(.portNowHeldByPID, ["port": "\(port)", "pid": "\($0)"]) }
                    ?? L(.portNowHeldByOther, ["port": "\(port)"])
                updateSnapshot {
                    $0.phase = .portConflict
                    $0.pid = pid
                    $0.startedAt = nil
                    $0.message = message
                    $0.isManaged = false
                }
                completion(false, message)
                return
            }
            launchedProcess = nil
            launchedLogHandle?.closeFile()
            launchedLogHandle = nil
            authenticatedURL = nil
            clearManagedRecord()
            updateSnapshot {
                $0.phase = .stopped
                $0.port = SettingsManager.shared.port
                $0.pid = nil
                $0.startedAt = nil
                $0.message = nil
                $0.isManaged = false
            }
            completion(true, nil)
        }
    }

    private func runExternalStopScript(port: Int, pid: Int32) -> ExternalStopOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c", Self.externalStopScript,
            "dsh-stop-external",
            "\(port)",
            "\(pid)"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let result = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n")
                .last
                .map(String.init) ?? ""
            switch result {
            case "STOPPED":
                return .stopped
            case "NONE":
                return .refused(L(.processAlreadyGone))
            case "MULTIPLE-LISTENERS":
                return .refused(L(.severalListeners, ["port": "\(port)"]))
            case "NOT-LISTENER":
                return .refused(L(.pidNotListener, ["pid": "\(pid)", "port": "\(port)"]))
            case "NOT-HARNESS":
                return .refused(L(.pidNotHarness, ["pid": "\(pid)"]))
            case "FORBIDDEN":
                return .refused(L(.pidBelongsToOtherUser, ["pid": "\(pid)"]))
            default:
                return .refused(result.isEmpty ? L(.failedToStopExternal) : result)
            }
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    private static func commandLine(for pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (output?.isEmpty == false) ? output : nil
    }

    private func launchAndWait(completion: @escaping (Bool, String?) -> Void) {
        let currentPort = port
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let dshPath = self.findDshBinary() else {
                DispatchQueue.main.async {
                    let message = L(.dshNotInstalled, ["command": Self.installCommand])
                    self.updateSnapshot {
                        $0.phase = .error
                        $0.dshPath = nil
                        $0.dshVersion = nil
                        $0.message = message
                    }
                    completion(false, message)
                }
                return
            }

            let version = self.readDshVersion(at: dshPath)
            do {
                let launchedAt = Date()
                let (process, logHandle, logOffset) = try self.launchProcess(path: dshPath, port: currentPort)
                var finalProbe: ProbeResult = .unavailable
                for _ in 0..<30 {
                    Thread.sleep(forTimeInterval: 0.5)
                    finalProbe = self.probe(port: currentPort)
                    if finalProbe.isHarness { break }
                    if case .foreign = finalProbe, !process.isRunning { break }
                }
                let launchAuthenticatedURL = self.captureAuthenticatedURL(
                    port: currentPort,
                    fromLogOffset: logOffset
                )

                DispatchQueue.main.async {
                    self.launchedProcess = process
                    self.launchedLogHandle = logHandle
                    self.updateSnapshot {
                        $0.dshPath = dshPath
                        $0.dshVersion = version
                    }

                    switch finalProbe {
                    case let .harness(pid, detectedStart):
                        guard pid == process.processIdentifier else {
                            if process.isRunning { process.terminate() }
                            self.clearManagedRecord()
                            let message = L(.portServedByOther, ["port": "\(currentPort)"])
                            self.updateSnapshot {
                                $0.phase = .portConflict
                                $0.port = currentPort
                                $0.pid = pid
                                $0.startedAt = detectedStart
                                $0.message = message
                                $0.isManaged = false
                            }
                            completion(false, message)
                            return
                        }
                        // Store the *process's* start time, not the moment we
                        // called spawn: probes compare this against `ps etime`,
                        // and using our own call time would fold node's cold
                        // start into the comparison. A slow start would then
                        // look like PID reuse and silently demote a healthy
                        // managed service to external.
                        let record = ManagedServiceRecord(
                            pid: process.processIdentifier,
                            port: currentPort,
                            startedAt: detectedStart ?? launchedAt,
                            executablePath: dshPath
                        )
                        self.saveManagedRecord(record)
                        self.authenticatedURL = launchAuthenticatedURL
                        self.updateSnapshot {
                            $0.phase = .running
                            $0.port = currentPort
                            $0.pid = process.processIdentifier
                            $0.startedAt = detectedStart ?? launchedAt
                            $0.message = SettingsManager.shared.port == currentPort
                                ? nil
                                : L(.portChangedRestartToApply, ["port": "\(SettingsManager.shared.port)"])
                            $0.isManaged = true
                        }
                        completion(true, nil)
                    case let .foreign(pid):
                        if process.isRunning { process.terminate() }
                        self.clearManagedRecord()
                        let message = pid.map { L(.portUsedByPID, ["port": "\(currentPort)", "pid": "\($0)"]) }
                            ?? L(.portAlreadyInUse, ["port": "\(currentPort)"])
                        self.updateSnapshot {
                            $0.phase = .portConflict
                            $0.pid = pid
                            $0.startedAt = nil
                            $0.message = message
                            $0.isManaged = false
                        }
                        completion(false, message)
                    case .unavailable:
                        if process.isRunning { process.terminate() }
                        self.clearManagedRecord()
                        let message = L(.serviceNotReady, ["port": "\(currentPort)"])
                        self.updateSnapshot {
                            $0.phase = .error
                            $0.pid = nil
                            $0.startedAt = nil
                            $0.message = message
                            $0.isManaged = false
                        }
                        completion(false, message)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    let message = L(.launchFailed, ["reason": error.localizedDescription])
                    self.updateSnapshot {
                        $0.phase = .error
                        $0.message = message
                    }
                    completion(false, message)
                }
            }
        }
    }

    private func launchProcess(path: String, port: Int) throws -> (Process, FileHandle, UInt64) {
        let logURL = logFileURL
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(
                atPath: logURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        let logHandle = try FileHandle(forWritingTo: logURL)
        let logOffset = logHandle.seekToEndOfFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["web", "--no-open"] + (port == 3080 ? [] : ["--port", "\(port)"])
        process.environment = Self.commandEnvironment()
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()

        try "\(process.processIdentifier)\n".write(
            to: pidFileURL,
            atomically: true,
            encoding: .utf8
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidFileURL.path)
        return (process, logHandle, logOffset)
    }

    private func runStopScript(port: Int) -> StopResult {
        let startEpoch = managedRecord.map { "\(Int($0.startedAt.timeIntervalSince1970))" } ?? ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c", Self.stopScript,
            "dsh-stop",
            pidFileURL.path,
            "\(port)",
            startEpoch
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let result = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n")
                .last
                .map(String.init) ?? ""
            switch result {
            case "STOPPED": return .stopped
            case "FOREIGN-LISTENER", "UNVERIFIED-PID": return .foreign
            case "NONE": return .none
            default: return .failed(result)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func finishStop(
        result: StopResult,
        probe: ProbeResult,
        port: Int,
        completion: @escaping (Bool, String?) -> Void
    ) {
        switch (result, probe) {
        case (_, .harness):
            let message = L(.stillResponding, ["port": "\(port)"])
            updateSnapshot {
                $0.phase = .error
                $0.message = message
            }
            completion(false, message)
        case (.foreign, _), (_, .foreign):
            let message = L(.portUsedByAnotherApp, ["port": "\(port)"])
            // The recorded process is gone or no longer owns the port, so the
            // stored identity must not survive to a future launch.
            clearManagedRecord()
            updateSnapshot {
                $0.phase = .portConflict
                $0.startedAt = nil
                $0.message = message
                $0.isManaged = false
            }
            completion(false, message)
        case let (.failed(reason), _):
            let message = reason.isEmpty ? L(.failedToStopService) : reason
            updateSnapshot {
                $0.phase = .error
                $0.message = message
            }
            completion(false, message)
        default:
            launchedProcess = nil
            launchedLogHandle?.closeFile()
            launchedLogHandle = nil
            authenticatedURL = nil
            // Drop the persisted identity too, so a later launch never probes or
            // claims a port that this app has already released.
            clearManagedRecord()
            updateSnapshot {
                $0.phase = .stopped
                $0.port = SettingsManager.shared.port
                $0.pid = nil
                $0.startedAt = nil
                $0.message = nil
                $0.isManaged = false
            }
            completion(true, nil)
        }
    }

    private static let stopScript = """
    PIDFILE="$1"; PORT="$2"; START_EPOCH="$3"
    export PATH="/usr/sbin:/sbin:/usr/bin:/bin:/opt/homebrew/bin:$PATH"

    etime_seconds() {
      t="$1"
      [ -n "$t" ] || { echo ""; return; }
      d=0
      case "$t" in
        *-*) d="${t%%-*}"; t="${t#*-}" ;;
      esac
      oldIFS="$IFS"; IFS=:
      set -- $t
      IFS="$oldIFS"
      case $# in
        3) echo $(( d * 86400 + $1 * 3600 + $2 * 60 + $3 )) ;;
        2) echo $(( d * 86400 + $1 * 60 + $2 )) ;;
        *) echo "" ;;
      esac
    }

    # Only the process this app recorded is a candidate. Anything else on the
    # port is reported as foreign and left completely alone.
    p=""
    if [ -f "$PIDFILE" ]; then
      candidate=$(tr -dc '0-9' < "$PIDFILE" 2>/dev/null || true)
      if [ -n "$candidate" ] && kill -0 "$candidate" 2>/dev/null; then
        listeners=$(lsof -ti :"$PORT" -sTCP:LISTEN 2>/dev/null || true)
        case " $listeners " in
          *" $candidate "*) p="$candidate" ;;
        esac
      fi
    fi

    if [ -z "$p" ]; then
      rm -f "$PIDFILE"
      if [ -n "$(lsof -ti :"$PORT" -sTCP:LISTEN 2>/dev/null || true)" ]; then
        echo "FOREIGN-LISTENER"; exit 5
      fi
      echo "NONE"; exit 4
    fi

    # Guard against PID reuse: the live process start time must match the
    # recorded launch time, otherwise this is a different process. A missing
    # fingerprint is treated as unverifiable rather than as "no check needed".
    if [ -z "$START_EPOCH" ]; then
      echo "UNVERIFIED-PID"; exit 6
    fi
    actual=$(ps -p "$p" -o etime= 2>/dev/null | tr -d ' ')
    actual_s=$(etime_seconds "$actual")
    if [ -z "$actual_s" ]; then
      echo "UNVERIFIED-PID"; exit 6
    fi
    now=$(date +%s)
    expected=$(( now - START_EPOCH ))
    drift=$(( actual_s - expected ))
    [ "$drift" -lt 0 ] && drift=$(( -drift ))
    if [ "$drift" -gt 30 ]; then
      echo "UNVERIFIED-PID"; exit 6
    fi

    kill "$p" 2>/dev/null || true
    i=0
    while [ $i -lt 20 ]; do
      kill -0 "$p" 2>/dev/null || break
      sleep 0.15
      i=$((i + 1))
    done
    if kill -0 "$p" 2>/dev/null; then
      kill -9 "$p" 2>/dev/null || true
      sleep 0.3
    fi
    rm -f "$PIDFILE"
    echo "STOPPED"
    exit 0
    """

    /// Terminates a service the user explicitly confirmed, even though DSH Bar
    /// did not start it. Safety comes from re-checking, inside the script, that
    /// the caller-supplied PID owns its process, is the *only* listener on the
    /// port, and really answers as DeepSeek Harness.
    private static let externalStopScript = """
    PORT="$1"; PID="$2"
    export PATH="/usr/sbin:/sbin:/usr/bin:/bin:/opt/homebrew/bin:$PATH"

    alive() {
      st=$(ps -p "$1" -o stat= 2>/dev/null | tr -d ' ')
      [ -n "$st" ] || return 1
      case "$st" in Z*) return 1 ;; esac
      return 0
    }

    is_harness_http() {
      body=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null | head -c 4096 | tr 'A-Z' 'a-z')
      case "$body" in
        *"dsh web"*|*"__dsh_boot__"*|*"deepseek harness"*) return 0 ;;
        *) return 1 ;;
      esac
    }

    case "$PID" in
      ''|*[!0-9]*) echo "NO-PID"; exit 9 ;;
    esac
    alive "$PID" || { echo "NONE"; exit 4; }

    owner=$(ps -p "$PID" -o user= 2>/dev/null | tr -d ' ')
    [ "$owner" = "$(id -un)" ] || { echo "FORBIDDEN"; exit 7; }

    listeners=$(lsof -ti :"$PORT" -sTCP:LISTEN 2>/dev/null || true)
    [ -n "$listeners" ] || { echo "NONE"; exit 4; }

    case " $listeners " in
      *" $PID "*) ;;
      *) echo "NOT-LISTENER"; exit 8 ;;
    esac

    count=$(echo "$listeners" | wc -l | tr -d ' ')
    [ "$count" = "1" ] || { echo "MULTIPLE-LISTENERS"; exit 10; }

    is_harness_http || { echo "NOT-HARNESS"; exit 11; }

    kill "$PID" 2>/dev/null || true
    i=0
    while [ $i -lt 20 ]; do
      alive "$PID" || break
      sleep 0.15
      i=$((i + 1))
    done
    if alive "$PID"; then
      kill -9 "$PID" 2>/dev/null || true
      sleep 0.3
    fi

    alive "$PID" && { echo "STILL-RUNNING"; exit 12; }
    echo "STOPPED"
    exit 0
    """

    // MARK: - Unexpected exit and recovery

    /// A service we started vanished without being asked to. Notify, then try a
    /// bounded restart. External services are deliberately never resurrected:
    /// their lifetime belongs to the terminal that started them, where a
    /// deliberate Ctrl-C is indistinguishable from a crash.
    private func handleUnexpectedExit(pid: Int32?, port: Int) {
        lastUnexpectedExit = Date()
        lastUnexpectedExitPID = pid
        let description = pid.map { L(.pidLabel, ["pid": "\($0)"]) } ?? L(.theService)
        let message = L(.stoppedUnexpectedly, ["who": description, "port": "\(port)"])
        updateSnapshot {
            $0.phase = .stopped
            $0.message = message
        }
        ServiceNotifier.shared.notifyUnexpectedExit(pid: pid, port: port)
        scheduleAutoRestart()
    }

    private func scheduleAutoRestart() {
        guard autoRestartEnabled else { return }
        pruneAutoRestartAttempts()
        guard autoRestartAttempts.count < Self.autoRestartMaxAttempts else {
            // Already recovered as often as we allow in this window. Stop, and
            // record it durably instead of looping forever.
            recoverySuspended = true
            updateSnapshot {
                $0.message = L(.keepsStopping, [
                    "attempts": "\(Self.autoRestartMaxAttempts)",
                    "minutes": "\(Int(Self.autoRestartWindow / 60))"
                ])
            }
            ServiceNotifier.shared.notifyGaveUp()
            return
        }

        let index = min(autoRestartAttempts.count, Self.autoRestartBackoff.count - 1)
        let delay = Self.autoRestartBackoff[index]
        autoRestartAttempts.append(Date())

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.autoRestartWorkItem = nil
            // The user may have started it themselves, or stopped everything, in
            // the meantime. Only act if the service is still down.
            guard !self.snapshot.isRunning, !self.snapshot.phase.isBusy else { return }
            self.beginLaunch(acknowledgeCrash: false) { success, message in
                if success {
                    ServiceNotifier.shared.notifyAutoRestarted(
                        attempt: self.autoRestartAttempts.count
                    )
                } else {
                    ServiceNotifier.shared.notifyUnexpectedExit(pid: nil, port: self.port)
                    self.scheduleAutoRestart()
                }
            }
        }
        autoRestartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Drops attempts that fell outside the rate-limit window.
    private func pruneAutoRestartAttempts() {
        let cutoff = Date().addingTimeInterval(-Self.autoRestartWindow)
        autoRestartAttempts.removeAll { $0 < cutoff }
    }

    /// Cancels a queued recovery. Called whenever the user takes control, so a
    /// deliberate stop is never undone by a pending automatic restart.
    func cancelPendingAutoRestart() {
        autoRestartWorkItem?.cancel()
        autoRestartWorkItem = nil
        autoRestartAttempts.removeAll()
    }

    /// Marks the next disappearance as expected. Paired with
    /// `endIntentionalStop()` on every exit path of a stop/restart.
    private func beginIntentionalStop() {
        intentionalStopInFlight = true
    }

    private func endIntentionalStop() {
        intentionalStopInFlight = false
    }

    /// Called on quit so nothing fires while the app is being torn down. The
    /// managed record is intentionally left on disk: that is what lets a later
    /// launch re-adopt a service that is still running.
    func prepareForTermination() {
        stopMonitoring()
        autoRestartWorkItem?.cancel()
        autoRestartWorkItem = nil
    }

    /// Quit path that also stops the service DSH Bar started.
    func stopServiceForQuit(completion: @escaping (Bool, String?) -> Void) {
        cancelPendingAutoRestart()
        guard snapshot.isRunning, snapshot.isManaged else {
            // Nothing of ours is running; quitting must not touch a service the
            // user started elsewhere.
            completion(true, nil)
            return
        }
        stopService(completion: completion)
    }

    // MARK: - User Actions

    func openBrowser() {
        // Only the token captured from this app's own launch is trusted. A
        // token mined from historical log text could belong to a dead process.
        NSWorkspace.shared.open(authenticatedURL ?? baseUrl)
    }

    /// DSH prints a process-token URL when it starts with `--no-open`. Only the
    /// bytes appended by *this* launch are scanned, and the token is kept in
    /// memory — it is never shown in the UI, the clipboard, or written elsewhere.
    private func captureAuthenticatedURL(port: Int, fromLogOffset offset: UInt64) -> URL? {
        Self.extractAuthenticatedURL(port: port, fromLogOffset: offset)
    }

    private static func extractAuthenticatedURL(port: Int, fromLogOffset offset: UInt64) -> URL? {
        let url = ServiceManager.shared.logFileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let sizeValue = attributes[.size] as? NSNumber,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }

        let size = sizeValue.uint64Value
        // If the file was rotated or truncated, only the current tail is usable.
        let start = size >= offset ? offset : (size > 131_072 ? size - 131_072 : 0)
        handle.seek(toFileOffset: start)
        let data = handle.readDataToEndOfFile()
        handle.closeFile()
        var text = String(decoding: data, as: UTF8.self)
        if let ansiRegex = try? NSRegularExpression(pattern: "\\u001B\\[[0-9;]*[A-Za-z]") {
            text = ansiRegex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }

        let pattern = "https?://(?:127\\.0\\.0\\.1|localhost):\(port)[^\\s\\\"']*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var cleanFallback: URL?
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text),
                  let candidate = URL(string: String(text[range])),
                  let components = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
                  components.port == port,
                  let host = components.host?.lowercased(),
                  host == "127.0.0.1" || host == "localhost" else {
                continue
            }
            if components.query != nil {
                return candidate
            }
            cleanFallback = cleanFallback ?? candidate
        }
        return cleanFallback
    }

    /// Replaces the process token in log text so the exported/shared view never
    /// leaks it. Used by the live log window and the log redaction preview.
    static func redactingProcessTokens(in text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "(https?://(?:127\\.0\\.0\\.1|localhost):[0-9]+/)[?][^\\s\\\"']*",
            options: [.caseInsensitive]
        ) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1<redacted>"
        )
    }

    func revealLogFile() {
        let url = logFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(logDirectory)
        }
    }

    func copyURLToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(baseUrl.absoluteString, forType: .string)
    }
}

/// Thread-safe holder for the result of a bounded HTTP probe. The URLSession
/// callback and the `probe(port:)` timeout path both touch it, so access is
/// serialized instead of relying on unsynchronized value capture.
private final class HTTPProbeBox {
    private let lock = NSLock()
    private var data: Data?
    private var response: HTTPURLResponse?

    func store(data: Data?, response: HTTPURLResponse?) {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
        self.response = response
    }

    func snapshot() -> (data: Data?, response: HTTPURLResponse?) {
        lock.lock()
        defer { lock.unlock() }
        return (data, response)
    }
}
