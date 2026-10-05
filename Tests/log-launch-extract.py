#!/usr/bin/env python3
"""Compile the real ServiceManager launch method in a small runtime harness."""
from pathlib import Path
import sys

repo = Path(__file__).resolve().parent.parent
source = (repo / "Sources/ServiceManager.swift").read_text()
start = source.index("    private func launchProcess(")
end = source.index("\n    private func runStopScript(", start)
method = source[start:end].replace("private func launchProcess", "func launchProcess", 1)
assert "LogWriterProcess.start(" in method, "Web still opens a direct unbounded log"
assert "defer {" in method and "closeParentPipeHandles()" in method
assert "process.standardOutput = logger.outputHandle" in method
assert "process.standardError = logger.outputHandle" in method
assert method.index("LogWriterProcess.start(") < method.index("try process.run()")
assert "process.terminate()" in method, "post-spawn failure can orphan Web"
assert "fromLogOffset" not in source and "extractAuthenticatedURL" not in source
window = (repo / "Sources/LogWindow.swift").read_text()
assert "LogFileIdentity.read(from: handle)" in window and "self.readIdentity = identity" in window
assert "previous: previousIdentity, current: identity" in window
assert "readDataToEndOfFile()" not in window and "generation == self.fillGeneration" in window
header = r'''import Foundation
import Darwin
final class LaunchHarness {
    let logFileURL: URL
    let markerURL: URL
    let destination: URL
    init(log: URL, marker: URL, destination: URL) {
        self.logFileURL = log; self.markerURL = marker; self.destination = destination
    }
    var pidFileURL: URL {
        // Wait for the fake Web's PID marker, making post-spawn failure checks
        // deterministic without altering the production launch method.
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: markerURL.path) { usleep(10_000) }
        return destination
    }
    static func commandEnvironment() -> [String: String] { ProcessInfo.processInfo.environment }
'''
Path(sys.argv[1]).write_text(header + method + "\n}\n")
