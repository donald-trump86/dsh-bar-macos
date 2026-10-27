import Foundation
import Darwin

/// A cancellation gate shared by stage transitions and the atomic process spawn.
final class InstallCancellation {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        if isCancelled { throw DshVersionControllerError.cancelled }
    }
    func whileActive<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw DshVersionControllerError.cancelled }
        return try body()
    }
}

/// Owns only the process group created by this spawn, through cleanup and reap.
struct InstallProcess {
    static func run(executable: String, arguments: [String], environment: [String: String],
                    cancellation: InstallCancellation, output: (Data) -> Void) throws -> Int32 {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw posixError(errno) }
        let readFD = descriptors[0], writeFD = descriptors[1]
        var writeOpen = true
        defer { close(readFD); if writeOpen { close(writeFD) } }
        guard fcntl(readFD, F_SETFL, O_NONBLOCK) != -1,
              fcntl(readFD, F_SETFD, FD_CLOEXEC) != -1,
              fcntl(writeFD, F_SETFD, FD_CLOEXEC) != -1 else { throw posixError(errno) }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO))
        try check(posix_spawn_file_actions_addclose(&actions, readFD))
        try check(posix_spawn_file_actions_addclose(&actions, writeFD))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        try cancellation.whileActive {
            let status = argv.withUnsafeBufferPointer { args in
                envp.withUnsafeBufferPointer { env in
                    posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
                }
            }
            try check(status)
        }
        close(writeFD)
        writeOpen = false

        var buffer = [UInt8](repeating: 0, count: 8192)
        var exitObserved = false
        var termAt: TimeInterval?
        var killAt: TimeInterval?
        var observationError: Error?
        while true {
            // Bound each drain pass so a noisy child cannot starve cancellation/exit checks.
            for _ in 0..<16 {
                let count = read(readFD, &buffer, buffer.count)
                if count > 0 { output(Data(buffer.prefix(count))) }
                else { break }
            }
            if !exitObserved {
                var info = siginfo_t()
                if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
                    exitObserved = info.si_pid == pid
                } else if errno != EINTR {
                    // Never signal an identifier after losing ownership of its leader.
                    observationError = posixError(errno)
                    break
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            if termAt == nil && (cancellation.isCancelled || exitObserved) {
                _ = kill(-pid, SIGTERM)
                termAt = now
            }
            if let termAt, killAt == nil, now - termAt >= 0.6 {
                // WNOWAIT keeps the leader reserved until the last group signal.
                _ = kill(-pid, SIGKILL)
                killAt = now
            }
            if let killAt, exitObserved, now - killAt >= 0.1 { break }
            var descriptor = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 25)
            // A pipe at EOF is always readable; avoid spinning while descendants clean up.
            if descriptor.revents & Int16(POLLHUP) != 0 { usleep(10_000) }
        }
        if let observationError { throw observationError }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { throw posixError(errno) }
        }
        try cancellation.check()
        // Darwin's wait status macros are unavailable in Swift.
        return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }

    private static func check(_ status: Int32) throws {
        guard status == 0 else { throw posixError(status) }
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
