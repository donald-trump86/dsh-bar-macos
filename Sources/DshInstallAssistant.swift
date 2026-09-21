import Cocoa

enum DshInstallAssistant {
    static func present() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let npmInstalled = ServiceManager.shared.findNpmBinary() != nil
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "DeepSeek Harness CLI Is Not Installed"

        if npmInstalled {
            alert.informativeText = "DSH Bar could not find the ‘dsh’ command. The official npm installation command is:\n\n\(ServiceManager.installCommand)\n\nThe command can be copied and Terminal opened for you."
            alert.addButton(withTitle: "Copy Command & Open Terminal")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            copyInstallCommand()
            openTerminal()
        } else {
            alert.informativeText = "DSH Bar could not find either ‘dsh’ or ‘npm’. Install Node.js/npm first, then run:\n\n\(ServiceManager.installCommand)"
            alert.addButton(withTitle: "Open Node.js Website")
            alert.addButton(withTitle: "Copy Command")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if let url = URL(string: "https://nodejs.org/en/download") {
                    NSWorkspace.shared.open(url)
                }
            case .alertSecondButtonReturn:
                copyInstallCommand()
            default:
                break
            }
        }
    }

    private static func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ServiceManager.installCommand, forType: .string)
    }

    private static func openTerminal() {
        guard let terminal = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal"
        ) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: terminal, configuration: configuration)
    }
}
