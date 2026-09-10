import Foundation

/// Login runs in an isolated home so adding an account never replaces the active session.
@MainActor @Observable
final class AccountLogin {
    private var process: Process?
    private var cancelled = false

    func cancel() {
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }

    func run(executable: URL, timeout: Duration = .seconds(300)) async throws -> Credential {
        guard process == nil else { throw SwitchError(message: L10n.text("login_busy")) }
        cancelled = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexAccountLogin-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let task = Process()
        defer {
            process = nil
            try? FileManager.default.removeItem(at: directory)
        }
        task.executableURL = executable
        task.arguments = ["login", "-c", "cli_auth_credentials_store=\"file\""]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = directory.path
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_ACCESS_TOKEN")
        task.environment = environment
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        process = task
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while task.isRunning && !cancelled && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { cancel() }
        }
        let timedOut = ContinuousClock.now >= deadline
        if task.isRunning {
            task.terminate()
            for _ in 0..<20 {
                if !task.isRunning { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            // Only the login subprocess started above is eligible for forced cleanup.
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            while task.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        }
        guard !cancelled else { throw SwitchError(message: L10n.text("login_cancelled")) }
        guard !timedOut else { throw SwitchError(message: L10n.text("login_timeout")) }
        guard task.terminationStatus == 0 else {
            throw SwitchError(message: L10n.text("login_failed"))
        }
        return try Credential(data: Data(contentsOf: directory.appendingPathComponent("auth.json")))
    }
}
