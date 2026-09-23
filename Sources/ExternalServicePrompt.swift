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
            case .stop: return L(.extStopButton)
            case .restart: return L(.adoptRestart)
            }
        }

        var explanation: String {
            switch self {
            case .stop:
                return L(.extStopExplain)
            case .restart:
                return L(.extRestartExplain)
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
            alert.messageText = L(.extTitle)
            let processLine = L(.extProcessLabel, ["command": info.command])
            let idLine = "\(L(.pidLabel, ["pid": "\(info.pid)"]))   •   \(L(.serverPort)): \(info.port)"
            alert.informativeText = """
            \(processLine)
            \(idLine)

            \(action.explanation)
            """

            alert.addButton(withTitle: action.buttonTitle)
            alert.addButton(withTitle: L(.cancel))

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
