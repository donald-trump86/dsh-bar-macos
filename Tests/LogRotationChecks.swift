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
    }
}
