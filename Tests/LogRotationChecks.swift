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
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
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
