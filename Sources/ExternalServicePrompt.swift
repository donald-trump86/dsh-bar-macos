import Cocoa

/// Confirmation shown before DSH Bar touches a DeepSeek Harness process it did
/// not start. The dialog always names the exact PID, port and command line, so
/// consent is informed rather than implied by a generic "Stop" button.
enum ExternalServicePrompt {
    enum Action {
        case stop
        case restart

        var buttonTitle: String {
            switch self {
            case .stop: return "Stop Process"
            case .restart: return "Adopt & Restart"
            }
        }

        var explanation: String {
            switch self {
            case .stop:
                return "DSH Bar did not start it, so stopping it terminates that process. "
                    + "Your terminal will report the server as stopped."
            case .restart:
                return "DSH Bar will stop that process and start the service itself, "
                    + "so Stop and Restart work normally from now on."
            }
        }
    }

    static func confirm(action: Action, completion: @escaping (Bool) -> Void) {
        ServiceManager.shared.describeUnmanagedService { info in
            guard let info else {
                completion(false)
                return
            }

            NSApplication.shared.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "DeepSeek Harness Was Started Outside DSH Bar"
            alert.informativeText = """
            Process: \(info.command)
            PID: \(info.pid)   •   Port: \(info.port)

            \(action.explanation)
            """

            alert.addButton(withTitle: action.buttonTitle)
            alert.addButton(withTitle: "Cancel")

            let confirmed = alert.runModal() == .alertFirstButtonReturn
            // The PID can be reused or the service can exit while the dialog is
            // open, so re-validate against the live snapshot before acting.
            guard confirmed,
                  ServiceManager.shared.snapshot.pid == info.pid,
                  ServiceManager.shared.snapshot.port == info.port else {
                completion(false)
                return
            }
            completion(true)
        }
    }
}
