import Foundation

@MainActor
struct UnmanagedServer {
    static func socketOwners(_ output: String, path: String) -> Set<Int32> {
        var current: Int32?
        var owners = Set<Int32>()
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("p") { current = Int32(line.dropFirst()) }
            if line == "n" + path, let current { owners.insert(current) }
        }
        return owners
    }

    static func isExpectedServer(command: String, arguments: String, socket: String) -> Bool {
        let executable = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let args = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(fileURLWithPath: executable).lastPathComponent == "codex" else { return false }
        return args == executable + " app-server --listen unix://" || args == executable + " app-server --listen unix://" + socket
    }

    static func owners(socket: URL, home: URL) async throws -> Set<Int32> {
        if !FileManager.default.fileExists(atPath: socket.path) { return [] }
        let result = try await DaemonCommand.run(executable: URL(fileURLWithPath: "/usr/sbin/lsof"), arguments: ["-n", "-a", "-U", "-Fpn", socket.path], home: home)
        if !FileManager.default.fileExists(atPath: socket.path) { return [] }
        guard result.status == 0 || (result.status == 1 && result.output.isEmpty) else {
            throw SwitchError(message: L10n.text("socket_unknown"))
        }
        return socketOwners(result.output, path: socket.path)
    }

    static func stop(socket: URL, home: URL) async throws {
        let initialOwners = try await owners(socket: socket, home: home)
        guard initialOwners.count == 1, let pid = initialOwners.first else {
            throw SwitchError(message: L10n.text("server_ambiguous"))
        }
        func field(_ name: String) async throws -> String {
            let result = try await DaemonCommand.run(executable: URL(fileURLWithPath: "/bin/ps"), arguments: ["-p", String(pid), "-o", name + "="], home: home)
            guard result.status == 0 else { throw SwitchError(message: L10n.text("process_unknown")) }
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let uid = try await field("uid")
        let command = try await field("comm")
        let arguments = try await field("args")
        guard uid == String(getuid()), isExpectedServer(command: command, arguments: arguments, socket: socket.path),
              try await owners(socket: socket, home: home) == initialOwners else {
            throw SwitchError(message: L10n.text("server_mismatch"))
        }
        // Signal only the verified owner of this CODEX_HOME's exact control socket.
        guard kill(pid, SIGTERM) == 0 else { throw SwitchError(message: L10n.text("server_stop_failed")) }
        for _ in 0..<100 {
            if kill(pid, 0) != 0 && errno == ESRCH {
                guard try await owners(socket: socket, home: home).isEmpty else {
                    throw SwitchError(message: L10n.text("server_restarted"))
                }
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SwitchError(message: L10n.text("server_not_stopped"))
    }
}
