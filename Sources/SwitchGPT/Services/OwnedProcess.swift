import Foundation

/// Owns a process group and keeps its leader unreaped until every group member is stopped.
/// Foundation Process supplies launch settings only, so early leader exit cannot release its PID.
final class OwnedProcess: @unchecked Sendable {
    private let configuration: Process
    private let pid: pid_t
    private let lock = NSLock()
    private var reaped = false

    init(_ configuration: Process, input: Int32? = nil, output: Int32? = nil) throws {
        self.configuration = configuration
        pid = try Self.spawn(configuration, input: input, output: output)
        // Only the child uses these pipe ends. Keeping them open here would hide EOF.
        if input == nil { try? (configuration.standardInput as? Pipe)?.fileHandleForReading.close() }
        if output == nil { try? (configuration.standardOutput as? Pipe)?.fileHandleForWriting.close() }
        try? (configuration.standardError as? Pipe)?.fileHandleForWriting.close()
    }

    deinit { stop() }

    var isRunning: Bool {
        lock.withLock {
            guard !reaped else { return false }
            var info = siginfo_t()
            var result: Int32
            repeat { result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) }
            while result == -1 && errno == EINTR
            return result == 0 && info.si_pid == 0
        }
    }

    /// Reads a completed leader's exit status without freeing its PID before group cleanup.
    func terminationStatus() throws -> Int32 {
        try lock.withLock {
            guard !reaped else { throw CocoaError(.executableNotLoadable) }
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == -1 {
                if errno == EINTR { continue }
                try Self.check(errno)
            }
            guard info.si_pid == pid else { throw CocoaError(.executableNotLoadable) }
            return info.si_status
        }
    }

    /// Safe to call repeatedly, including after the leader has exited. No signals follow reaping.
    func stop() {
        lock.withLock {
            guard !reaped else { return }
            kill(-pid, SIGTERM)
            let grace = ContinuousClock.now.advanced(by: .milliseconds(200))
            while Self.groupHasLiveProcesses(pid) && ContinuousClock.now < grace { usleep(10_000) }
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR { }
            reaped = true
        }
    }

    private static func groupHasLiveProcesses(_ group: pid_t) -> Bool {
        let size = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard size > 0 else { return false }
        var members = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 16)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), &members, Int32(members.count * MemoryLayout<pid_t>.size))
        return members.prefix(max(0, Int(bytes)) / MemoryLayout<pid_t>.size).contains { pid in
            guard pid > 0 else { return false }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return false }
            return info.pbi_status != UInt32(SZOMB)
        }
    }

    private static func spawn(_ process: Process, input: Int32?, output: Int32?) throws -> pid_t {
        guard let executable = process.executableURL else { throw CocoaError(.fileNoSuchFile) }
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        func redirect(_ source: Any?, to descriptor: Int32, override: Int32? = nil) throws {
            if let override { try check(posix_spawn_file_actions_adddup2(&actions, override, descriptor)); return }
            if let handle = source as? FileHandle, handle === FileHandle.nullDevice {
                try check(posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0))
            } else {
                let pipe = source as? Pipe
                let fd = (source as? FileHandle)?.fileDescriptor
                    ?? (descriptor == STDIN_FILENO ? pipe?.fileHandleForReading.fileDescriptor : pipe?.fileHandleForWriting.fileDescriptor)
                    ?? descriptor
                try check(posix_spawn_file_actions_adddup2(&actions, fd, descriptor))
            }
        }
        try redirect(process.standardInput, to: STDIN_FILENO, override: input)
        try redirect(process.standardOutput, to: STDOUT_FILENO, override: output)
        try redirect(process.standardError, to: STDERR_FILENO)
        if let directory = process.currentDirectoryURL {
            if #available(macOS 26, *) { try check(posix_spawn_file_actions_addchdir(&actions, directory.path)) }
            else { try check(posix_spawn_file_actions_addchdir_np(&actions, directory.path)) }
        }
        var arguments = ([executable.path] + (process.arguments ?? [])).map { strdup($0) } + [nil]
        var environment = (process.environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for item in arguments { free(item) }; for item in environment { free(item) } }
        var pid: pid_t = 0
        try check(posix_spawn(&pid, executable.path, &actions, &attributes, &arguments, &environment))
        return pid
    }

    private static func check(_ error: Int32) throws {
        guard error == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
    }
}
