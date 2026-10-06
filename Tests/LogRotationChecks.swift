import Foundation
import Darwin

@main
struct LogRotationChecks {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "--internal-log-writer" {
            guard args.count == 4, args[2].hasPrefix("/"),
                  let port = Int(args[3]), (1...65535).contains(port) else { exit(64) }
            exit(RotatingLogWriter.run(logURL: URL(fileURLWithPath: args[2]), port: port))
        }
        // An actual parent process exercising the same launcher used by Bar.
        if args.count > 1, args[1] == "--parent" {
            let writer = try LogWriterProcess.start(logURL: URL(fileURLWithPath: args[2]), port: 3080)
            defer { writer.closeParentPipeHandles() }
            let count = Int(args[3])!
            let bytes = Data(repeating: 97, count: count)
            try writer.outputHandle.write(contentsOf: bytes)
            // The parent exits without waiting for its logger. The process
            // check acquires the lifetime lock to observe the completed drain.
            print(writer.processIdentifier)
            return
        }
        assert(RotatingLogWriter.maximumFileBytes == 10 * 1024 * 1024)
        func url(_ text: String) -> URL? { RotatingLogWriter.authenticatedURL(in: text, port: 3080) }
        assert(url("http://127.0.0.1:3080/?token=current\n")?.query == "token=current")
        assert(url("\u{1B}[32mhttp://localhost:3080/?token=current\u{1B}[0m\n")?.host == "localhost")
        assert(url("http://127.0.0.1:3081/?token=wrong\n") == nil)
        assert(url("http://127.0.0.1:30800/?token=wrong\n") == nil)
        assert(url("http://evil.example:3080/?token=wrong\n") == nil)
        assert(url("http://localhost:3080@evil.example/?token=wrong\n") == nil)
        assert(url("http://localhost:3080/?token=partial") == nil)
        assert(url("http://localhost:3080/\n") == nil)
        print("PASS Swift production constants and launch URL validation")
        try checkRealLaunch()
        try checkFileIdentity()
        try checkLogTextBuffer()
        try checkByteRotationRedaction()
    }

    static func checkLogTextBuffer() throws {
        let redact = LaunchHarness.redactingProcessTokens
        let token = "synthetic-secret-fragment"
        let urls = [
            "http://127.0.0.1:3080/?token=\(token)",
            "http://localhost:3080/ui?token=\(token)",
            "http://localhost:3080?token=\(token)",
            "HTTP://LOCALHOST:3080/nested/ui?x=1&token=\(token)"
        ]
        for url in urls {
            assert(RotatingLogWriter.authenticatedURL(in: url + "\n", port: 3080) != nil)
            let line = "ready \(url)\n"
            let bytes = Data(line.utf8)
            let expected = redact(line)
            assert(!expected.contains(token) && expected.contains("<redacted>"))
            // Every possible two-read boundary, including inside scheme/query/token.
            for split in 0..<bytes.count {
                var buffer = LogTextBuffer()
                buffer.append(bytes.prefix(split), redacting: redact)
                assert(buffer.text.isEmpty, "incomplete line became visible")
                buffer.append(bytes.suffix(bytes.count - split), redacting: redact)
                assert(buffer.text == expected)
            }
            var tiny = LogTextBuffer(maximumBufferedBytes: 12)
            tiny.append(bytes, redacting: redact)
            assert(tiny.text.utf8.count <= 12 && !tiny.text.contains("fragment"))
        }
        let unicodeLine = "中文🙂e\u{301}\n"
        let unicode = Data(unicodeLine.utf8)
        for split in 0..<unicode.count {
            var buffer = LogTextBuffer()
            buffer.append(unicode.prefix(split), redacting: redact)
            buffer.append(unicode.suffix(unicode.count - split), redacting: redact)
            assert(buffer.text == unicodeLine, "split UTF-8 scalar was corrupted")
        }
        var partial = LogTextBuffer()
        partial.reset(discardPartialLine: true)
        partial.append(Data("secret-fragment".utf8), redacting: redact)
        assert(partial.text.isEmpty)
        partial.append(Data("-continued\nsafe\n".utf8), redacting: redact)
        assert(partial.text == "safe\n", "tail fragment leaked")
        partial.append(Data("http://localhost:3080/?token=unfinished".utf8), redacting: redact)
        partial.reset(discardPartialLine: false)
        partial.append(Data("rotated\n".utf8), redacting: redact)
        assert(partial.text == "safe\nrotated\n", "rotation joined unrelated fragments")
        var oversized = LogTextBuffer(maximumLineBytes: 16)
        oversized.append(Data(repeating: 97, count: 17), redacting: redact)
        oversized.append(Data("secret-fragment\nsafe\n".utf8), redacting: redact)
        assert(oversized.text == "safe\n", "oversized line suffix leaked")
        var bounded = LogTextBuffer(maximumBufferedBytes: 64)
        for _ in 0..<8 {
            bounded.append(Data((String(repeating: "\u{301}", count: 1024) + "\n").utf8), redacting: redact)
            assert(bounded.text.utf8.count <= 64 && !bounded.text.contains("\u{FFFD}"))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-log-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("boundaries")
        try Data("line\npartial".utf8).write(to: path)
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        let fromBeginning = try LogTextBuffer.startsMidLine(handle: handle, offset: 0)
        let afterNewline = try LogTextBuffer.startsMidLine(handle: handle, offset: 5)
        let midLine = try LogTextBuffer.startsMidLine(handle: handle, offset: 6)
        let atEOF = try LogTextBuffer.startsMidLine(handle: handle, offset: 12)
        assert(fromBeginning && !afterNewline && midLine && atEOF)
        print("PASS redaction before byte trimming; split URLs/UTF-8, tail/Clear/rotation and oversized lines")
    }

    static func checkByteRotationRedaction() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = temporaryRoot.appendingPathComponent("dsh-byte-redaction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            precondition(directory.resolvingSymlinksInPath().path == directory.path
                         && directory.deletingLastPathComponent().path == temporaryRoot.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let path = directory.appendingPathComponent("current")
        let process = Process()
        let input = Pipe()
        process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--internal-log-writer", path.path, "3080"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForReading.closeFile()
        defer {
            input.fileHandleForWriting.closeFile()
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        let prefix = Data("http://localhost:3080/ui?token=synthetic-".utf8)
        var padding = Data(repeating: 97, count: RotatingLogWriter.maximumFileBytes - prefix.count - 1)
        padding.append(10)
        try input.fileHandleForWriting.write(contentsOf: padding)
        try input.fileHandleForWriting.write(contentsOf: prefix)
        let continuation = Data("secret-suffix\nsafe\n".utf8)
        try input.fileHandleForWriting.write(contentsOf: continuation)
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        assert(process.terminationStatus == 0)
        let archive = try FileHandle(forReadingFrom: URL(fileURLWithPath: path.path + ".1"))
        defer { try? archive.close() }
        let (oldIdentity, oldSize) = try LogFileIdentity.read(from: archive)
        assert(oldSize == UInt64(RotatingLogWriter.maximumFileBytes))
        let current = try FileHandle(forReadingFrom: path)
        defer { try? current.close() }
        let (identity, size) = try LogFileIdentity.read(from: current)
        assert(identity != oldIdentity && size == UInt64(continuation.count))
        // Both opening the window and following rotation see a small file at zero.
        for previous: LogFileIdentity? in [nil, oldIdentity] {
            let offset = LogFileIdentity.readOffset(size: size, offset: oldSize,
                                                   previous: previous, current: identity)
            assert(offset == 0)
            var buffer = LogTextBuffer()
            buffer.append(prefix, redacting: LaunchHarness.redactingProcessTokens)
            buffer.reset(discardPartialLine: try LogTextBuffer.startsMidLine(handle: current, offset: offset))
            try current.seek(toOffset: offset)
            buffer.append(try current.read(upToCount: 512 * 1024) ?? Data(),
                          redacting: LaunchHarness.redactingProcessTokens)
            assert(buffer.text == "safe\n", "byte rotation exposed a zero-offset token suffix")
        }
        print("PASS actual byte rotation inside token hides zero-offset fragments on open and follow")
    }

    static func checkFileIdentity() throws {
        let old = LogFileIdentity(device: 1, inode: 2)
        let fresh = LogFileIdentity(device: 1, inode: 3)
        assert(LogFileIdentity.readOffset(size: 100, offset: 80, previous: old, current: fresh) == 0)
        assert(LogFileIdentity.readOffset(size: 100, offset: 80, previous: old, current: old) == 80)
        assert(LogFileIdentity.readOffset(size: 60, offset: 80, previous: old, current: old) == 0)
        assert(LogFileIdentity.readOffset(size: 1024 * 1024, offset: 0, previous: nil, current: fresh) == 512 * 1024)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("current")
        try Data(repeating: 1, count: 80).write(to: path)
        let oldHandle = try FileHandle(forReadingFrom: path)
        defer { try? oldHandle.close() }
        let (before, _) = try LogFileIdentity.read(from: oldHandle)
        try FileManager.default.moveItem(at: path, to: directory.appendingPathComponent("archive"))
        try Data(repeating: 2, count: 100).write(to: path)
        let currentHandle = try FileHandle(forReadingFrom: path)
        defer { try? currentHandle.close() }
        let (current, size) = try LogFileIdentity.read(from: currentHandle)
        assert(before != current && size == 100)
        assert(LogFileIdentity.readOffset(size: size, offset: 80, previous: before, current: current) == 0)
        let (stillOld, oldSize) = try LogFileIdentity.read(from: oldHandle)
        assert(stillOld == before && oldSize == 80, "identity must follow the opened FD, not its replaced pathname")
        print("PASS real inode replacement/regrowth and bounded-tail offsets")
    }

    static func checkRealLaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-web")
        let marker = directory.appendingPathComponent("spawned.pid")
        let destination = directory.appendingPathComponent("pidfile")
        // Ignore TERM to demand actual cleanup, not just sending one signal.
        let script = "#!/bin/sh\ntrap '' TERM\necho $$ > '\(marker.path)'\nprintf 'http://127.0.0.1:3080/?token=launch-only\\n'\nexec /bin/sleep 60\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let service = LaunchHarness(log: directory.appendingPathComponent("logs/dsh-web.log"), marker: marker, destination: destination)
        let (process, logger) = try service.launchProcess(path: executable.path, port: 3080)
        assert(process.isRunning)
        let storedPID = try String(contentsOf: destination, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        assert(storedPID == "\(process.processIdentifier)")
        for _ in 0..<100 where logger.authenticatedURL == nil { usleep(10_000) }
        assert(logger.authenticatedURL?.query == "token=launch-only")
        // Same production cleanup used when the final readiness probe fails.
        LaunchHarness.terminateFailedLaunch(process)
        assert(!process.isRunning, "readiness failure retained the Web/logger pipe")
        // The second start waits finitely for EOF and logger lock release.
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: marker)
        var refused = false
        do { _ = try service.launchProcess(path: executable.path, port: 3080) }
        catch { refused = true }
        assert(refused, "PID persistence unexpectedly succeeded into a directory")
        let failedPID = Int32(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        for _ in 0..<100 where kill(failedPID, 0) == 0 { usleep(10_000) }
        let survived = kill(failedPID, 0) == 0
        if survived { kill(failedPID, SIGKILL) } // never leave the test's fake Web behind
        assert(!survived, "PID-write failure left a TERM-ignoring untracked Web alive")
        print("PASS real Web launch preserves PID/auth; post-spawn failure fully cleans up")
    }
}
