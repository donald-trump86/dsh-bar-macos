import Foundation
import AppKit

final class ServiceManager {
    static let shared = ServiceManager()
    
    var port: Int {
        return SettingsManager.shared.port
    }
    
    var baseUrl: URL {
        return URL(string: "http://127.0.0.1:\(port)")!
    }
    
    private(set) var isRunning: Bool = false

    // Status changes are broadcast to every observer (menu bar and preferences
    // panel) instead of a single callback slot that later registrants overwrite.
    private var statusObservers: [UUID: (Bool) -> Void] = [:]
    private var portObserverToken: UUID?

    @discardableResult
    func addStatusObserver(_ observer: @escaping (Bool) -> Void) -> UUID {
        let token = UUID()
        statusObservers[token] = observer
        observer(isRunning) // deliver the current value immediately
        return token
    }

    func removeStatusObserver(_ token: UUID) {
        statusObservers.removeValue(forKey: token)
    }

    private func notifyStatusObservers(_ running: Bool) {
        for observer in Array(statusObservers.values) {
            observer(running)
        }
    }
    
    private var timer: Timer?
    private let session: URLSession
    
    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.0
        config.timeoutIntervalForResource = 1.0
        self.session = URLSession(configuration: config)
        
        portObserverToken = SettingsManager.shared.addPortObserver { [weak self] _ in
            self?.checkStatus()
        }
    }
    
    func startMonitoring(interval: TimeInterval = 2.0) {
        checkStatus()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkStatus()
        }
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    /// Body markers that only the DeepSeek Harness web server serves, so an
    /// unrelated process squatting on the port is not mistaken for Harness.
    /// Unauthenticated it answers 401 with "dsh web authentication required …";
    /// the authenticated shell injects `__DSH_BOOT__`.
    private static let harnessMarkers = ["dsh web", "__dsh_boot__", "deepseek harness"]
    
    func checkStatus(completion: ((Bool) -> Void)? = nil) {
        var request = URLRequest(url: baseUrl)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            let running: Bool
            if let httpResponse = response as? HTTPURLResponse {
                let body = String(data: data ?? Data(), encoding: .utf8)?.lowercased() ?? ""
                let reachable = (200...599).contains(httpResponse.statusCode)
                running = reachable && Self.harnessMarkers.contains { body.contains($0) }
            } else {
                running = false
            }
            
            DispatchQueue.main.async {
                guard let self = self else { return }
                let changed = (self.isRunning != running)
                self.isRunning = running
                if changed {
                    self.notifyStatusObservers(running)
                }
                completion?(running)
            }
        }
        task.resume()
    }
    
    func findDshBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/dsh",
            "/usr/local/bin/dsh",
            "\(NSHomeDirectory())/.local/bin/dsh"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        
        // Search in system PATH via which
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["dsh"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        
        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    var logDirectory: URL {
        let dshDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dsh/logs")
        if !FileManager.default.fileExists(atPath: dshDir.path) {
            try? FileManager.default.createDirectory(at: dshDir, withIntermediateDirectories: true)
        }
        return dshDir
    }
    
    var logFileURL: URL {
        return logDirectory.appendingPathComponent("dsh-web.log")
    }
    
    /// Records the PID of the server this app launched, so "Stop Service" never
    /// has to guess which process owns the port.
    var pidFileURL: URL {
        let dshDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dsh")
        if !FileManager.default.fileExists(atPath: dshDir.path) {
            try? FileManager.default.createDirectory(at: dshDir, withIntermediateDirectories: true)
        }
        return dshDir.appendingPathComponent("dsh-web.pid")
    }
    
    func startService(completion: @escaping (Bool, String?) -> Void) {
        guard let dshPath = findDshBinary() else {
            completion(false, "Could not find 'dsh' binary. Please make sure DeepSeek Harness is installed.")
            return
        }
        
        // Prepare log file
        let logPath = logFileURL.path
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        
        let currentPort = self.port
        let portArg = (currentPort == 3080) ? "" : "--port \(currentPort)"
        let pidPath = pidFileURL.path
        
        // Launch in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            
            // Build bash wrapper with proper PATH & locale; remember the server PID.
            let script = """
            export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$HOME/.local/bin:$PATH"
            export LANG="en_US.UTF-8"
            export LC_ALL="en_US.UTF-8"
            nohup "\(dshPath)" web \(portArg) >> "\(logPath)" 2>&1 &
            echo $! > "\(pidPath)"
            """
            process.arguments = ["-c", script]
            
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    completion(false, "Failed to launch process: \(error.localizedDescription)")
                }
                return
            }
            
            // Poll for ready state up to 15 seconds
            var ready = false
            for _ in 0..<30 {
                Thread.sleep(forTimeInterval: 0.5)
                let semaphore = DispatchSemaphore(value: 0)
                var currentRunning = false
                self.checkStatus { isRunning in
                    currentRunning = isRunning
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 1.0)
                if currentRunning {
                    ready = true
                    break
                }
            }
            
            DispatchQueue.main.async {
                if ready {
                    completion(true, nil)
                } else {
                    completion(false, "Service started but timed out waiting for port \(currentPort) to respond.")
                }
            }
        }
    }
    
    /// Stops the Harness server that belongs to this app.
    ///
    /// Safety: the previous implementation ran `kill $(lsof -ti :port)`, which also
    /// matched *clients* connected to the port — including the user's browser and
    /// this app itself (it polls the port every 2s). Now only listeners are
    /// considered, and only the PID recorded at launch or a single listener that
    /// answers with the Harness marker is signalled. See `stopScript`.
    func stopService(completion: @escaping (Bool, String?) -> Void) {
        let currentPort = self.port
        let pidPath = pidFileURL.path
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", Self.stopScript, "dsh-stop", pidPath, String(currentPort)]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            var output = ""
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } catch {
                DispatchQueue.main.async {
                    completion(false, "Failed to run stop script: \(error.localizedDescription)")
                }
                return
            }
            
            let result = output.split(separator: "\n").last.map(String.init) ?? ""
            Thread.sleep(forTimeInterval: 0.4)
            
            self.checkStatus { stillRunning in
                DispatchQueue.main.async {
                    switch result {
                    case "STOPPED":
                        if stillRunning {
                            completion(false, "The server is still responding on port \(currentPort).")
                        } else {
                            completion(true, nil)
                        }
                    case "FOREIGN-LISTENER":
                        completion(false, "Port \(currentPort) is in use by another application, not DeepSeek Harness. Nothing was stopped.")
                    case "NONE":
                        completion(!stillRunning, stillRunning
                            ? "Could not identify the DeepSeek Harness process on port \(currentPort)."
                            : "DeepSeek Harness is not running on port \(currentPort).")
                    default:
                        completion(!stillRunning, stillRunning
                            ? "Failed to stop the service on port \(currentPort)."
                            : nil)
                    }
                }
            }
        }
    }
    
    /// Finds the right process without ever touching an unrelated one.
    /// Prints exactly one of: STOPPED / FOREIGN-LISTENER / NONE.
    ///
    /// Identification is deliberately dependency-free: the recorded PID is only
    /// trusted while it still owns the port, and a manually started server is
    /// adopted only when the port answers with the Harness marker AND exactly one
    /// process listens on it. Clients (browser, this app) are never candidates.
    private static let stopScript = """
    PIDFILE="$1"; PORT="$2"
    export PATH="/usr/sbin:/sbin:/usr/bin:/bin:/opt/homebrew/bin:$PATH"

    is_harness_http() {
      body=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null | head -c 4096 | tr 'A-Z' 'a-z')
      case "$body" in
        *"dsh web"*|*"__dsh_boot__"*|*"deepseek harness"*) return 0 ;;
        *) return 1 ;;
      esac
    }

    listeners=$(lsof -ti :"$PORT" -sTCP:LISTEN 2>/dev/null || true)
    targets=""

    # 1) The server this app launched, as long as it still owns the port.
    if [ -f "$PIDFILE" ]; then
      p=$(tr -dc '0-9' < "$PIDFILE" 2>/dev/null || true)
      if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
        case " $listeners " in
          *" $p "*) targets="$p" ;;
        esac
      fi
    fi

    # 2) Otherwise adopt the sole listener, but only if it really is Harness.
    if [ -z "$targets" ] && [ -n "$listeners" ]; then
      count=$(printf '%s\\n' $listeners | wc -l | tr -d ' ')
      if [ "$count" = "1" ] && is_harness_http; then targets="$listeners"; fi
    fi

    if [ -z "$targets" ]; then
      rm -f "$PIDFILE"
      if [ -n "$listeners" ]; then echo "FOREIGN-LISTENER"; exit 5; fi
      echo "NONE"; exit 4
    fi

    kill $targets 2>/dev/null || true
    i=0
    while [ $i -lt 20 ]; do
      [ -z "$(lsof -ti :"$PORT" -sTCP:LISTEN 2>/dev/null || true)" ] && break
      sleep 0.15
      i=$((i + 1))
    done
    if [ -n "$(lsof -ti :"$PORT" -sTCP:LISTEN 2>/dev/null || true)" ]; then
      kill -9 $targets 2>/dev/null || true
      sleep 0.3
    fi
    rm -f "$PIDFILE"
    echo "STOPPED"
    exit 0
    """
    
    func restartService(completion: @escaping (Bool, String?) -> Void) {
        stopService { [weak self] stopped, message in
            guard let self = self else { return }
            // A foreign process on the port is a hard stop; report instead of
            // racing it with a doomed start.
            if !stopped, let message = message, message.contains("not DeepSeek Harness") {
                completion(false, message)
                return
            }
            Thread.sleep(forTimeInterval: 0.8)
            self.startService(completion: completion)
        }
    }
    
    func openBrowser() {
        NSWorkspace.shared.open(baseUrl)
    }
    
    func openLogs() {
        let logPath = logFileURL.path
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(logFileURL)
        } else {
            if let consoleApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") {
                NSWorkspace.shared.openApplication(at: consoleApp, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }
    
    func copyURLToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(baseUrl.absoluteString, forType: .string)
    }
}
