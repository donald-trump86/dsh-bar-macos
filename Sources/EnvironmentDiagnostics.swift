import Foundation

struct CommandDiagnostic: Equatable {
    let path: String?
    let version: String?

    var isUsable: Bool { path != nil && version != nil }
}

struct EnvironmentDiagnostics: Equatable {
    let dsh: CommandDiagnostic
    let node: CommandDiagnostic
    let npm: CommandDiagnostic
    let searchPath: String

    static func inspect(environment: [String: String]) -> EnvironmentDiagnostics {
        func check(_ name: String) -> CommandDiagnostic {
            let path = findExecutable(named: name, environment: environment)
            return CommandDiagnostic(path: path, version: path.flatMap { version(at: $0, environment: environment) })
        }
        return EnvironmentDiagnostics(dsh: check("dsh"), node: check("node"), npm: check("npm"),
                                      searchPath: environment["PATH"] ?? "")
    }

    static func findExecutable(named name: String, environment: [String: String]) -> String? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            // The app's environment supplies absolute directories. Never search
            // its working directory through an empty or relative PATH entry.
            guard directory.hasPrefix("/") else { continue }
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
               !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    static func version(at path: String, environment: [String: String]) -> String? {
        let cancellation = InstallCancellation()
        let timeout = DispatchWorkItem { cancellation.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: timeout)
        defer { timeout.cancel() }
        var retained = Data()
        do {
            let status = try InstallProcess.run(executable: path, arguments: ["--version"],
                                               environment: environment, cancellation: cancellation) { data in
                retained.append(data.prefix(max(0, 4096 - retained.count)))
            }
            guard status == 0, !cancellation.isCancelled else { return nil }
        } catch {
            return nil
        }
        // Ignore warnings, but never turn arbitrary error output into a version.
        return String(decoding: retained, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.range(of: #"^v?[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#,
                              options: .regularExpression) != nil }
    }

    func findings(for snapshot: ServiceSnapshot) -> [String] {
        var findings: [String] = []
        for (name, command) in [("Node", node), ("npm", npm), ("DSH", dsh)] {
            if command.path == nil {
                findings.append(L(.diagnosticsCommandMissing, ["command": name]))
            } else if !command.isUsable {
                findings.append(L(.diagnosticsCommandFailed, ["command": name]))
            }
        }
        if !node.isUsable || !npm.isUsable {
            findings.append(L(.diagnosticsNodeAdvice))
        } else if !dsh.isUsable {
            findings.append(L(.diagnosticsDshAdvice))
        }
        if snapshot.phase == .portConflict {
            findings.append(L(.diagnosticsPortAdvice, ["port": "\(snapshot.port)"]))
        }
        if snapshot.needsVersionRestart, let running = snapshot.runningDshVersion,
           let installed = snapshot.dshVersion {
            findings.append(L(.diagnosticsRestartAdvice, ["running": running, "installed": installed]))
        } else if snapshot.isRunning && snapshot.runningDshVersion == nil {
            findings.append(L(.diagnosticsUnknownVersion))
        }
        if snapshot.phase == .error {
            findings.append(L(.diagnosticsLogAdvice))
        }
        return findings.isEmpty ? [L(.diagnosticsCommandsOK)] : findings
    }

    var report: String {
        var lines: [String] = []
        for (name, command) in [("DSH", dsh), ("Node", node), ("npm", npm)] {
            lines.append("\(name) path: \(command.path ?? "not found")")
            lines.append("\(name) version: \(command.version ?? "unverified")")
        }
        lines.append("Command PATH: \(searchPath)")
        return lines.joined(separator: "\n")
    }
}
