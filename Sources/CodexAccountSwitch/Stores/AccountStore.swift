import SwiftUI

@MainActor @Observable
final class AccountStore {
    var accounts: [Account] = []
    var message = ""
    var addingAccount = false
    private let login = AccountLogin()
    var busy = false
    var currentID: String?
    var resetDetails: [String: ResetCreditDetails] = [:]
    var usages: [String: AccountUsage] = [:]
    var usageErrors: [String: String] = [:]
    var usageUpdatedAt: [String: Date] = [:]
    var loadingUsage = false
    var emails: [String: String] = [:]
    private let vault = Vault()
    private let session = CodexSession()
    private let index: URL

    init(index: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexAccountSwitch/accounts.json")) {
        self.index = index
        do {
            if FileManager.default.fileExists(atPath: index.path) {
                accounts = try JSONDecoder().decode([Account].self, from: Data(contentsOf: index))
            }
            refresh()
        } catch { message = L10n.text("list_read") }
    }
    func refresh() { currentID = try? session.read().id }
    func displayName(_ account: Account) -> String { emails[account.id] ?? L10n.text("email_loading") }
    func refreshUsage() async {
        guard !loadingUsage, !busy else { return }
        loadingUsage = true
        defer { loadingUsage = false }
        refresh()
        for account in accounts {
            do {
                let current = try? session.read()
                let credential: Credential
                if let current, current.id == account.id { credential = current }
                else { credential = try Credential(data: vault.read(account.id)) }
                emails[account.id] = credential.email ?? L10n.text("email_missing")
                usages[account.id] = try await UsageClient().fetch(credential)
                if (usages[account.id]?.rateLimitResetCredits?.availableCount ?? 0) > 0 {
                    resetDetails[account.id] = try? await UsageClient().fetchResetCredits(credential)
                } else { resetDetails[account.id] = nil }
                usageUpdatedAt[account.id] = .now
                usageErrors[account.id] = nil
            } catch {
                usageErrors[account.id] = L10n.text("unavailable_prefix") + error.localizedDescription
            }
        }
    }
    @discardableResult
    func reorder(_ sourceID: String, onto targetID: String) -> Bool {
        guard !busy, sourceID != targetID,
              let source = accounts.firstIndex(where: { $0.id == sourceID }),
              let target = accounts.firstIndex(where: { $0.id == targetID }) else { return false }
        let previous = accounts
        let account = accounts.remove(at: source)
        accounts.insert(account, at: target)
        do { try persist(); return true }
        catch { accounts = previous; message = L10n.text("order_save"); return false }
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(accounts).write(to: index, options: .atomic)
    }
    private func store(_ credential: Credential) throws {
        let label = credential.email ?? L10n.text("email_missing")
        emails[credential.id] = label
        try vault.save(credential.data, id: credential.id)
        let previous = accounts
        accounts.removeAll { $0.id == credential.id || $0.id == credential.id.components(separatedBy: "|")[0] }
        accounts.append(Account(id: credential.id, name: label, savedAt: .now))
        do { try persist() } catch { accounts = previous; throw error }
        refresh()
    }
    func addAccount() async {
        guard !busy else { return }
        busy = true
        addingAccount = true
        defer { busy = false; addingAccount = false }
        do {
            let executable = try session.appURL().appendingPathComponent("Contents/Resources/codex")
            message = L10n.text("login_browser")
            let credential = try await login.run(executable: executable)
            try store(credential)
            message = ""
        } catch { message = error.localizedDescription }
    }
    func cancelLogin() { login.cancel() }
    func remove(_ account: Account) {
        do {
            try vault.remove(account.id)
            accounts.removeAll { $0.id == account.id }
            try persist()
            message = ""
        } catch { message = error.localizedDescription }
    }
    func switchTo(_ account: Account) async {
        guard !busy else { return }
        busy = true
        defer { busy = false; refresh() }
        do {
            try session.validateStore()
            let target = try Credential(data: vault.read(account.id))
            guard target.id == account.id || target.id.components(separatedBy: "|")[0] == account.id else { throw SwitchError(message: L10n.text("account_mismatch")) }
            let app = try session.appURL()
            // Make rollback possible before asking Codex to terminate.
            let initial = try session.read()
            try vault.save(initial.data, id: "rollback")
            message = L10n.text("stopping")
            try await session.stop(app: app)
            let previous = try session.read()
            try vault.save(previous.data, id: "rollback")
            if accounts.contains(where: { $0.id == previous.id }) { try vault.save(previous.data, id: previous.id) }
            // A refreshed token from the current account takes precedence over a saved snapshot.
            let freshTarget = previous.id == target.id ? previous : target
            do {
                try session.write(freshTarget)
                try await session.launch(app)
                message = ""
            } catch {
                do {
                    try await session.stop(app: app)
                    try session.write(previous)
                    try await session.launch(app)
                    message = L10n.text("rollback_ok")
                } catch {
                    message = L10n.text("rollback_failed")
                }
            }
        } catch { message = error.localizedDescription }
    }
}
