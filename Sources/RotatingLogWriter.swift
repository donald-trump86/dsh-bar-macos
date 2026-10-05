import Foundation
import Darwin

/// Single owner of the fixed current/.1/.2 slots. Web writes to its stdin,
/// never to a pathname that can be renamed underneath an open Web descriptor.
enum RotatingLogWriter {
    static let maximumFileBytes = 10 * 1024 * 1024
    private static let chunkBytes = 64 * 1024
    private static let captureBytes = 128 * 1024

    private static func failure(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Log writer: \(operation)"])
    }

    private static func checkedFile(_ path: String) throws -> stat? {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw failure("inspect log slot")
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
            throw NSError(domain: "DSHLogWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Unsafe log slot; expected an owned regular file"])
        }
        return info
    }

    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw failure("write log") }
            offset += count
        }
    }

    // Messages are bounded below PIPE_BUF. Never block the data sink on a Bar
    // that stopped reading; ignoring SIGPIPE also makes normal Quit harmless.
    private static func control(_ message: String) {
        let data = Data(message.utf8)
        guard data.count <= 4096 else { return }
        data.withUnsafeBytes { bytes in
            var result: Int
            repeat { result = Darwin.write(STDOUT_FILENO, bytes.baseAddress, bytes.count) }
            while result < 0 && errno == EINTR
        }
    }

    /// Only complete URLs from this launch, with a query and exact loopback
    /// host/port. Requiring a delimiter prevents capturing a split token prefix.
    static func authenticatedURL(in text: String, port: Int) -> URL? {
        let pattern = "https?://(?:127\\.0\\.0\\.1|localhost):[0-9]+[^\\s\\\"'\\x1B]*(?=[\\s\\\"'\\x1B])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text), text[range].utf8.count <= 2048,
                  let url = URL(string: String(text[range])),
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.port == port, parts.user == nil, parts.password == nil,
                  let host = parts.host?.lowercased(), host == "127.0.0.1" || host == "localhost",
                  let query = parts.query, !query.isEmpty else { continue }
            return url
        }
        return nil
    }

    /// Refuse legacy non-cooperating writers before replacing any existing log.
    /// Our lock protects new loggers; old Bar versions never acquired it.
    private static func ensureOffline(_ paths: [String]) throws {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-t", "--"] + existing
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // With three regular files this is a tiny PID list; consume it before
        // waiting so even many holders cannot deadlock the child on its pipe.
        let result = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        pipe.fileHandleForReading.closeFile()
        guard process.terminationStatus == 1, result.isEmpty else {
            throw NSError(domain: "DSHLogWriter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Existing logs are still open; stop the old log readers/writers before starting"])
        }
    }

    // Offline oversized files keep only a bounded suffix. Stream into a fixed
    // temporary slot and atomically replace; never truncate an active writer.
    private static func boundExisting(_ path: String) throws {
        guard let info = try checkedFile(path) else { return }
        guard chmod(path, 0o600) == 0 else { throw failure("set log permissions") }
        guard info.st_size > maximumFileBytes else { return }
        let source = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw failure("open legacy log") }
        defer { close(source) }
        let temporary = path + ".bounded-\(getpid())"
        let target = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard target >= 0 else { throw failure("create bounded legacy tail") }
        defer { close(target); _ = unlink(temporary) }
        guard lseek(source, info.st_size - off_t(maximumFileBytes), SEEK_SET) >= 0 else {
            throw failure("seek legacy tail")
        }
        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        var remaining = maximumFileBytes
        while remaining > 0 {
            let count = Darwin.read(source, &buffer, min(buffer.count, remaining))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw failure("read legacy tail") }
            try buffer.withUnsafeBytes { try writeAll(target, UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            remaining -= count
        }
        guard rename(temporary, path) == 0 else { throw failure("replace bounded legacy tail") }
    }

    private static func rotate(_ path: String) throws {
        let slots = [path, path + ".1", path + ".2"]
        // Check all slots before unlink/rename; in particular never recursively
        // delete a directory or follow a symlink in an archive position.
        for slot in slots { _ = try checkedFile(slot) }
        if unlink(slots[2]) != 0, errno != ENOENT { throw failure("remove oldest archive") }
        if rename(slots[1], slots[2]) != 0, errno != ENOENT { throw failure("move second archive") }
        if rename(slots[0], slots[1]) != 0, errno != ENOENT { throw failure("archive current log") }
    }

    private static func freshFile(_ path: String) throws -> Int32 {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("create current log") }
        return fd
    }

    static func run(logURL: URL, port: Int) -> Int32 {
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        // Foundation may already put the child in its own process group. If it
        // is not a group leader, detach its session too; no terminal is needed.
        _ = setsid()
        let flags = fcntl(STDOUT_FILENO, F_GETFL)
        if flags >= 0 { _ = fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK) }
        let path = logURL.path
        let directory = logURL.deletingLastPathComponent().path
        var lockFD: Int32 = -1
        var logFD: Int32 = -1
        defer {
            if logFD >= 0 { close(logFD) }
            if lockFD >= 0 { close(lockFD) }
        }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard chmod(directory, 0o700) == 0 else { throw failure("set log directory permissions") }
            let lockPath = path + ".lock"
            _ = try checkedFile(lockPath)
            lockFD = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lockFD >= 0, fchmod(lockFD, 0o600) == 0 else { throw failure("open ownership lock") }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EINTR else { throw failure("lock logs") }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw failure("log ownership lock timed out") }
                usleep(20_000)
            }
            let slots = [path, path + ".1", path + ".2"]
            for slot in slots { _ = try checkedFile(slot) }
            try ensureOffline(slots)
            for slot in slots { try boundExisting(slot) }
            if let current = try checkedFile(path), current.st_size > 0 {
                try rotate(path)
            } else if unlink(path) != 0, errno != ENOENT {
                throw failure("remove empty current log")
            }
            logFD = try freshFile(path)
        } catch {
            control("ERROR log initialization failed\n")
            return 1
        }
        control("READY\n")
        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        var fileBytes = 0
        var capture = Data()
        var captureFinished = false
        var sinkFailed = false
        while true {
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count == 0 { break }
            guard count > 0 else { control("ERROR log input failed\n"); return 1 }
            if !captureFinished {
                capture.append(contentsOf: buffer.prefix(min(count, captureBytes - capture.count)))
                if let url = authenticatedURL(in: String(decoding: capture, as: UTF8.self), port: port) {
                    control("URL \(url.absoluteString)\n")
                    captureFinished = true
                } else if capture.count == captureBytes {
                    captureFinished = true
                }
                if captureFinished { capture.removeAll(keepingCapacity: false) }
            }
            guard !sinkFailed else { continue }
            do {
                var offset = 0
                while offset < count {
                    if fileBytes == maximumFileBytes {
                        close(logFD)
                        logFD = -1
                        try rotate(path)
                        logFD = try freshFile(path)
                        fileBytes = 0
                    }
                    let length = min(count - offset, maximumFileBytes - fileBytes)
                    try buffer.withUnsafeBytes {
                        try writeAll(logFD, UnsafeRawBufferPointer(rebasing: $0[offset..<(offset + length)]))
                    }
                    fileBytes += length
                    offset += length
                }
            } catch {
                if logFD >= 0 { close(logFD); logFD = -1 }
                sinkFailed = true
                control("ERROR log sink failed; draining without persistence\n")
            }
        }
        if !captureFinished,
           let url = authenticatedURL(in: String(decoding: capture, as: UTF8.self) + "\n", port: port) {
            control("URL \(url.absoluteString)\n")
        }
        return 0
    }
}

/// Parent-side startup control only; the Bar never handles Web's byte stream.
final class LogWriterProcess {
    private final class ControlState {
        let lock = NSLock()
        let readiness = DispatchSemaphore(value: 0)
        var ready = false
        var url: URL?
    }

    private let process: Process
    private let input: Pipe
    private let state: ControlState
    let outputHandle: FileHandle
    var processIdentifier: Int32 { process.processIdentifier }
    var authenticatedURL: URL? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.url
    }

    private init(process: Process, input: Pipe, state: ControlState) {
        self.process = process
        self.input = input
        self.state = state
        self.outputHandle = input.fileHandleForWriting
    }

    static func start(logURL: URL, port: Int) throws -> LogWriterProcess {
        let process = Process()
        process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--internal-log-writer", logURL.path, "\(port)"]
        let input = Pipe()
        let control = Pipe()
        let state = ControlState()
        let writer = LogWriterProcess(process: process, input: input, state: state)
        process.standardInput = input
        process.standardOutput = control
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Process copied the child endpoints; only the producer write end
            // and the control read end must remain in Bar.
            input.fileHandleForReading.closeFile()
            control.fileHandleForWriting.closeFile()
            let reader = control.fileHandleForReading
            DispatchQueue.global(qos: .utility).async {
                defer { reader.closeFile(); state.readiness.signal() }
                var pending = Data()
                var total = 0
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    // FileHandle.read(upToCount:) can wait to fill its request
                    // on Darwin pipes; POSIX read returns the available READY
                    // bytes immediately, before Web has been spawned.
                    let count = Darwin.read(reader.fileDescriptor, &buffer, buffer.count)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    total += count
                    guard total <= 16 * 1024 else { break }
                    pending.append(contentsOf: buffer.prefix(count))
                    while let newline = pending.firstIndex(of: 10) {
                        let line = String(decoding: pending[..<newline], as: UTF8.self)
                        pending.removeSubrange(...newline)
                        state.lock.lock()
                        if line == "READY" {
                            state.ready = true
                            state.readiness.signal()
                        } else if line.hasPrefix("URL "), state.ready,
                                  let url = RotatingLogWriter.authenticatedURL(in: String(line.dropFirst(4)) + "\n", port: port) {
                            state.url = url
                        } else if line.hasPrefix("ERROR"), !state.ready {
                            state.lock.unlock()
                            return
                        }
                        state.lock.unlock()
                    }
                }
            }
            guard state.readiness.wait(timeout: .now() + 6) == .success else {
                throw NSError(domain: "DSHLogWriter", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Log writer readiness timed out"])
            }
            state.lock.lock()
            let ready = state.ready
            state.lock.unlock()
            guard ready else {
                throw NSError(domain: "DSHLogWriter", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "Log writer could not initialize (lock, permissions or an existing log holder)"])
            }
            return writer
        } catch {
            writer.closeParentPipeHandles()
            control.fileHandleForWriting.closeFile()
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    func closeParentPipeHandles() {
        try? input.fileHandleForReading.close()
        try? input.fileHandleForWriting.close()
    }

    deinit { closeParentPipeHandles() }
}
