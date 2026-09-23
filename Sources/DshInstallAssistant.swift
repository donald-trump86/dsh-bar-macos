import Cocoa

enum DshInstallAssistant {
    static func present() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let npmInstalled = ServiceManager.shared.findNpmBinary() != nil
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L(.installTitle)

        if npmInstalled {
            alert.informativeText = L(.installDshMissingBody, ["command": ServiceManager.installCommand])
            alert.addButton(withTitle: L(.installCopyAndOpenTerminal))
            alert.addButton(withTitle: L(.cancel))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            copyInstallCommand()
            openTerminal()
        } else {
            alert.informativeText = L(.installNpmMissingBody, ["command": ServiceManager.installCommand])
            alert.addButton(withTitle: L(.installOpenNodeSite))
            alert.addButton(withTitle: L(.installCopyCommand))
            alert.addButton(withTitle: L(.cancel))
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
