import AppKit

@MainActor
struct CodexSession {
    let home: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) { self.home = home }
    var auth: URL { home.appendingPathComponent("auth.json") }
    func read() throws -> Credential { try Credential(data: Data(contentsOf: auth)) }
    func validateStore() throws {
        let config = (try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        for line in config.components(separatedBy: .newlines) where line.trimmingCharacters(in: .whitespaces).hasPrefix("cli_auth_credentials_store") {
            let value = line.components(separatedBy: "#")[0]
            if !value.contains("\"file\"") && !value.contains("'file'") {
                throw SwitchError(message: L10n.text("store_unsupported"))
            }
        }
    }
    func appURL() throws -> URL {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            throw SwitchError(message: L10n.text("app_missing"))
        }
        return url
    }
    func stop(app: URL) async throws {
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex") {
            guard running.terminate() else { throw SwitchError(message: L10n.text("quit_refused")) }
        }
        for _ in 0..<150 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty else {
            throw SwitchError(message: L10n.text("still_running"))
        }
        let socket = home.appendingPathComponent("app-server-control/app-server-control.sock")
        // Closing the desktop app may already have removed its local server.
        if !FileManager.default.fileExists(atPath: socket.path) { return }
        let bundledCLI = app.appendingPathComponent("Contents/Resources/codex")
        let probe = try await DaemonCommand.run(executable: bundledCLI, arguments: ["app-server", "daemon", "version"], home: home)
        let executable = DaemonCommand.managedExecutable(from: probe.output) ?? bundledCLI
        let result = try await DaemonCommand.run(executable: executable, arguments: ["app-server", "daemon", "stop"], home: home)
        if !FileManager.default.fileExists(atPath: socket.path) { return }
        if result.status != 0 && result.output.contains("app server is running but is not managed by codex app-server daemon") {
            try await UnmanagedServer.stop(socket: socket, home: home)
            return
        }
        guard result.status == 0 else {
            throw SwitchError(message: L10n.format("server_stop_error", result.status, DaemonCommand.safeError(result.output)))
        }
    }

    func write(_ credential: Credential) throws {
        let temporary = home.appendingPathComponent(".account-switch-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw SwitchError(message: L10n.text("temp_failed"))
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: credential.data)
            try handle.synchronize()
            try handle.close()
        } catch { try? handle.close(); throw error }
        guard rename(temporary.path, auth.path) == 0 else {
            throw SwitchError(message: L10n.text("replace_failed"))
        }
        guard try read().id == credential.id else { throw SwitchError(message: L10n.text("verify_failed")) }
    }
    func launch(_ app: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty else {
            throw SwitchError(message: L10n.text("launch_failed"))
        }
    }
}
