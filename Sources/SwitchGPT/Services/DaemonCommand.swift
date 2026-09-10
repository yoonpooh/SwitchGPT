import Foundation

struct DaemonResult {
    let status: Int32
    let output: String
}

@MainActor
struct DaemonCommand {
    static func managedExecutable(from output: String) -> URL? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["managedCodexPath"] as? String,
              path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
    static func safeError(_ output: String) -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in [#"(?i)Bearer\s+\S+"#, #"eyJ[A-Za-z0-9_.-]+"#, #"sk-[A-Za-z0-9_-]+"#, #"https?://\S+"#] {
            text = text.replacingOccurrences(of: pattern, with: L10n.text("redacted"), options: .regularExpression)
        }
        return text.isEmpty ? L10n.text("stop_no_error") : String(text.prefix(500))
    }
    static func run(executable: URL, arguments: [String], home: URL) async throws -> DaemonResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexCommand-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        for _ in 0..<150 {
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        if process.isRunning {
            process.terminate()
            throw SwitchError(message: L10n.text("server_timeout"))
        }
        return DaemonResult(status: process.terminationStatus, output: (try? String(contentsOf: outputURL, encoding: .utf8)) ?? "")
    }
}
