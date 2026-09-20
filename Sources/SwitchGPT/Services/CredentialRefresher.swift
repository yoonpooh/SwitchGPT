import Foundation

/// Serializes refreshes per account and persists rotated tokens before any retry.
@MainActor
final class CredentialRefresher {
    private let client: TokenRefreshClient
    private var tasks: [String: Task<Credential, Error>] = [:]
    private var rejected: [String: Data] = [:]
    private var pending: [String: (original: Data, refreshed: Credential)] = [:]

    init(client: TokenRefreshClient = TokenRefreshClient()) { self.client = client }

    func refresh(_ credential: Credential,
                 load: @escaping @MainActor () throws -> Credential,
                 save: @escaping @MainActor (Credential) throws -> Void) async throws -> Credential {
        if let task = tasks[credential.id] { return try await task.value }
        let task = Task { @MainActor in
            let latest = try load()
            guard latest.id == credential.id else { throw SwitchError(message: L10n.text("account_mismatch")) }
            if latest.data != credential.data { return latest }
            if let saved = self.pending[credential.id], saved.original == latest.data {
                try save(saved.refreshed)
                self.pending[credential.id] = nil
                return saved.refreshed
            }
            if self.rejected[credential.id] == latest.data { throw RefreshFailure.reauthenticationRequired }
            let renewed: Credential
            do { renewed = try await self.client.refresh(latest) }
            catch RefreshFailure.reauthenticationRequired {
                self.rejected[credential.id] = latest.data
                throw RefreshFailure.reauthenticationRequired
            }
            self.pending[credential.id] = (latest.data, renewed)
            let current = try load()
            guard current.id == credential.id else { throw SwitchError(message: L10n.text("account_mismatch")) }
            // A new login or removal while the request was running wins over this response.
            guard current.data == latest.data else {
                self.pending[credential.id] = nil
                return current
            }
            try save(renewed)
            self.pending[credential.id] = nil
            self.rejected[credential.id] = nil
            return renewed
        }
        tasks[credential.id] = task
        defer { tasks[credential.id] = nil }
        return try await task.value
    }
}
