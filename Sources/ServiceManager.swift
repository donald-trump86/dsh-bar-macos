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
                    $0.message = "Configured port changed to \(newPort). It will apply after the current operation."
                }
            } else if self.snapshot.isRunning {
                // Keep the actual running port until the user restarts. Otherwise
                // changing the configured port would orphan the old listener.
                self.updateSnapshot {
                    $0.message = newPort == $0.port
                        ? nil
                        : "Configured port changed to \(newPort). Restart to apply it."
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
            if let record = managedRecord,
               record.port == port,
               record.pid == pid,
               let startedAt,
               abs(startedAt.timeIntervalSince(record.startedAt)) < 5 {
                isManaged = true
            } else if managedRecord?.port == port {
                clearManagedRecord()
            }
            if previousPID != pid {
                authenticatedURL = nil
            }
            updateSnapshot {
                $0.phase = .running
                $0.port = port
                $0.pid = pid
                $0.startedAt = startedAt ?? $0.startedAt
                $0.message = isManaged ? nil : "External DeepSeek Harness service"
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
                $0.message = pid.map { "Port \(port) is used by PID \($0)." }
                    ?? "Port \(port) is already in use."
                $0.isManaged = false
            }
        case .unavailable:
            if snapshot.isRunning, consecutiveProbeMisses < 1 {
                consecutiveProbeMisses += 1
                return
            }
            consecutiveProbeMisses = 0
            authenticatedURL = nil
            if managedRecord?.port == port {
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
        guard !snapshot.phase.isBusy else {
            completion(false, "A service operation is already in progress.")
            return
        }
        authenticatedURL = nil
        updateSnapshot {
            $0.phase = .starting
            $0.message = nil
        }
        launchAndWait(completion: completion)
    }

    func stopService(completion: @escaping (Bool, String?) -> Void) {
        guard !snapshot.phase.isBusy else {
            completion(false, "A service operation is already in progress.")
            return
        }
        guard snapshot.isManaged else {
            completion(false, "This service was not started by DSH Bar, so it will not be stopped.")
            return
        }
        let currentPort = snapshot.port
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
                self.finishStop(result: result, probe: probe, port: currentPort, completion: completion)
            }
        }
    }

    func restartService(completion: @escaping (Bool, String?) -> Void) {
        guard !snapshot.phase.isBusy else {
            completion(false, "A service operation is already in progress.")
            return
        }
        guard snapshot.isManaged else {
            completion(false, "This service was not started by DSH Bar, so it cannot be restarted safely.")
            return
        }
        let previousSnapshot = snapshot
        let previousAuthenticatedURL = authenticatedURL
        let currentPort = snapshot.isRunning ? snapshot.port : port
        let targetPort = port
        authenticatedURL = nil
        updateSnapshot {
            $0.phase = .restarting
            $0.message = nil
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if targetPort != currentPort {
                let targetProbe = self.probe(port: targetPort)
                if case .unavailable = targetProbe {
                    // Safe to move the service after confirming the new port is free.
                } else {
                    DispatchQueue.main.async {
                        let message = "Port \(targetPort) is already in use. The service is still running on port \(currentPort)."
                        self.authenticatedURL = previousAuthenticatedURL
                        self.updateSnapshot {
                            $0 = previousSnapshot
                            $0.message = message
                        }
                        completion(false, message)
                    }
                    return
                }
            }

            let stopResult = self.runStopScript(port: currentPort)
            if case let .failed(reason) = stopResult {
                DispatchQueue.main.async {
                    let message = reason.isEmpty ? "Failed to stop the existing service." : reason
                    self.authenticatedURL = previousAuthenticatedURL
                    self.updateSnapshot {
                        $0 = previousSnapshot
                        $0.message = message
                    }
                    completion(false, message)
                }
                return
            }
            if case .foreign = stopResult {
                DispatchQueue.main.async {
                    let message = "The listener on port \(currentPort) no longer matches the service started by DSH Bar."
                    self.clearManagedRecord()
                    self.updateSnapshot {
                        $0.phase = .portConflict
                        $0.message = message
                        $0.isManaged = false
                    }
                    completion(false, message)
                }
                return
            }

            Thread.sleep(forTimeInterval: 0.6)
            let stoppedProbe = self.probe(port: currentPort)
            guard case .unavailable = stoppedProbe else {
                DispatchQueue.main.async {
                    let message = "The old service is still listening on port \(currentPort); restart was cancelled."
                    self.authenticatedURL = previousAuthenticatedURL
                    self.updateSnapshot {
                        $0 = previousSnapshot
                        $0.message = message
                    }
                    completion(false, message)
                }
                return
            }

            DispatchQueue.main.async {
                self.clearManagedRecord()
                self.launchAndWait(completion: completion)
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
                        command: command ?? "PID \(pid)"
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
            completion(false, "A service operation is already in progress.")
            return
        }
        guard snapshot.isRunning, !snapshot.isManaged else {
            completion(false, unmanagedRefusalReason())
            return
        }
        guard snapshot.pid == pid else {
            completion(false, "That process is no longer the service on this port. Refresh and try again.")
            return
        }
        let currentPort = snapshot.port
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
            completion(false, "A service operation is already in progress.")
            return
        }
        guard snapshot.isRunning, !snapshot.isManaged else {
            completion(false, unmanagedRefusalReason())
            return
        }
        guard snapshot.pid == pid else {
            completion(false, "That process is no longer the service on this port. Refresh and try again.")
            return
        }
        let currentPort = snapshot.port
        let targetPort = port
        authenticatedURL = nil
        updateSnapshot {
            $0.phase = .restarting
            $0.message = nil
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
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
                    let message = "The external service is still listening on port \(currentPort); restart was cancelled."
                    self.updateSnapshot {
                        $0.phase = .portConflict
                        $0.message = message
                        $0.isManaged = false
                    }
                    completion(false, message)
                }
                return
            }

            if targetPort != currentPort {
                guard case .unavailable = self.probe(port: targetPort) else {
                    DispatchQueue.main.async {
                        let message = "Port \(targetPort) is already in use, so the service was not restarted."
                        self.updateSnapshot {
                            $0.phase = .portConflict
                            $0.port = targetPort
                            $0.message = message
                            $0.isManaged = false
                        }
                        completion(false, message)
                    }
                    return
                }
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
            return "Port \(snapshot.port) is held by a process that does not answer as DeepSeek Harness, so it was left alone."
        case .running:
            return "This service was started by DSH Bar, so use the normal Stop and Restart actions."
        default:
            return "DeepSeek Harness is not running, so there is nothing to stop."
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
                let message = "The process was terminated but port \(port) is still serving DeepSeek Harness."
                updateSnapshot {
                    $0.phase = .portConflict
                    $0.message = message
                    $0.isManaged = false
                }
                completion(false, message)
                return
            }
            if case let .foreign(pid) = probe {
                let message = pid.map { "Port \(port) is now held by PID \($0)." }
                    ?? "Port \(port) is now held by another process."
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
                return .refused("The process was already gone.")
            case "MULTIPLE-LISTENERS":
                return .refused("Several processes listen on port \(port), so nothing was stopped.")
            case "NOT-LISTENER":
                return .refused("PID \(pid) no longer listens on port \(port). Nothing was stopped.")
            case "NOT-HARNESS":
                return .refused("PID \(pid) does not answer as DeepSeek Harness, so it was left alone.")
            case "FORBIDDEN":
                return .refused("PID \(pid) belongs to another user or a protected process.")
            default:
                return .refused(result.isEmpty ? "Failed to stop the external service." : result)
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
                    let message = "DeepSeek Harness CLI is not installed. Install it with: \(Self.installCommand)"
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
                            let message = "Port \(currentPort) is already served by a different DeepSeek Harness process."
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
                        let record = ManagedServiceRecord(
                            pid: process.processIdentifier,
                            port: currentPort,
                            startedAt: launchedAt,
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
                                : "Configured port changed to \(SettingsManager.shared.port). Restart to apply it."
                            $0.isManaged = true
                        }
                        completion(true, nil)
                    case let .foreign(pid):
                        if process.isRunning { process.terminate() }
                        self.clearManagedRecord()
                        let message = pid.map { "Port \(currentPort) is used by PID \($0)." }
                            ?? "Port \(currentPort) is already in use."
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
                        let message = "Service did not become ready on port \(currentPort). Check the live logs for details."
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
                    let message = "Failed to launch DSH: \(error.localizedDescription)"
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
            let message = "The DeepSeek Harness service is still responding on port \(port)."
            updateSnapshot {
                $0.phase = .error
                $0.message = message
            }
            completion(false, message)
        case (.foreign, _), (_, .foreign):
            let message = "Port \(port) is used by another application. Nothing was stopped."
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
            let message = reason.isEmpty ? "Failed to stop the service." : reason
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
