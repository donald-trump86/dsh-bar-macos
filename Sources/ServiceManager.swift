import Foundation
import AppKit

final class ServiceManager {
    static let shared = ServiceManager()
    
    let port: Int = 3080
    var baseUrl: URL {
        return URL(string: "http://127.0.0.1:\(port)")!
    }
    
    private(set) var isRunning: Bool = false
    var onStatusChanged: ((Bool) -> Void)?
    
    private var timer: Timer?
    private let session: URLSession
    
    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.0
        config.timeoutIntervalForResource = 1.0
        self.session = URLSession(configuration: config)
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
    
    func checkStatus(completion: ((Bool) -> Void)? = nil) {
        var request = URLRequest(url: baseUrl)
        request.httpMethod = "GET"
        
        let task = session.dataTask(with: request) { [weak self] _, response, error in
            let running: Bool
            if let httpResponse = response as? HTTPURLResponse {
                // Any response from 127.0.0.1:3080 (including 401 Unauthorized) means Harness server is running
                running = (httpResponse.statusCode > 0)
            } else {
                running = false
            }
            
            DispatchQueue.main.async {
                guard let self = self else { return }
                let changed = (self.isRunning != running)
                self.isRunning = running
                if changed {
                    self.onStatusChanged?(running)
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
        
        // Launch in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            
            // Build bash wrapper with proper PATH & locale
            let script = """
            export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$HOME/.local/bin:$PATH"
            export LANG="en_US.UTF-8"
            export LC_ALL="en_US.UTF-8"
            nohup "\(dshPath)" web >> "\(logPath)" 2>&1 &
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
                    completion(false, "Service started but timed out waiting for port \(self.port) to respond.")
                }
            }
        }
    }
    
    func stopService(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            // Kill any process listening on port 3080
            let script = "PIDS=$(lsof -ti :\(self.port) 2>/dev/null || true); if [ -n \"$PIDS\" ]; then kill $PIDS 2>/dev/null || true; fi"
            process.arguments = ["-c", script]
            try? process.run()
            process.waitUntilExit()
            
            Thread.sleep(forTimeInterval: 0.5)
            self.checkStatus { isRunning in
                completion(!isRunning)
            }
        }
    }
    
    func restartService(completion: @escaping (Bool, String?) -> Void) {
        stopService { [weak self] stopped in
            guard let self = self else { return }
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
            // Open Console app
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
