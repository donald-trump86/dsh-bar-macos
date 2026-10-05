import Cocoa

@main
struct MainApp {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == "--internal-log-writer" {
            guard arguments.count == 4, arguments[2].hasPrefix("/"),
                  let port = Int(arguments[3]), (1...65535).contains(port) else { exit(64) }
            exit(RotatingLogWriter.run(logURL: URL(fileURLWithPath: arguments[2]), port: port))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
