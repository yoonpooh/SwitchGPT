import Foundation
import Observation
import Darwin

/// Persist before sending, so an interrupted redemption resumes with the same request ID.
@MainActor @Observable
final class ResetCreditLedger {
    private let file: URL
    private var attempts: [String: String] = [:]
    private(set) var readable = true

    init(file: URL) {
        self.file = file
        do { attempts = try read() }
        catch { readable = false }
    }

    func hasPending(_ accountID: String) -> Bool {
        attempts[RelayCredentials.fingerprint(accountID)] != nil
    }

    func pending(_ accountID: String) throws -> String? {
        attempts = try read()
        readable = true
        return attempts[RelayCredentials.fingerprint(accountID)]
    }

    func begin(_ accountID: String) throws -> String {
        try locked {
            var saved = try read()
            let key = RelayCredentials.fingerprint(accountID)
            let requestID = saved[key] ?? UUID().uuidString
            saved[key] = requestID
            try write(saved)
            attempts = saved
            readable = true
            return requestID
        }
    }

    func finish(_ accountID: String, requestID: String) throws {
        try locked {
            var saved = try read()
            let key = RelayCredentials.fingerprint(accountID)
            guard saved[key] == requestID else { throw SwitchError(message: L10n.text("reset_storage_error")) }
            saved.removeValue(forKey: key)
            try write(saved)
            attempts = saved
        }
    }

    private func read() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
        guard saved.values.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw SwitchError(message: L10n.text("reset_storage_error"))
        }
        return saved
    }

    private func write(_ saved: [String: String]) throws {
        try JSONEncoder().encode(saved).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func locked<T>(_ operation: () throws -> T) throws -> T {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SwitchError(message: L10n.text("reset_storage_error")) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw SwitchError(message: L10n.text("reset_storage_error")) }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
