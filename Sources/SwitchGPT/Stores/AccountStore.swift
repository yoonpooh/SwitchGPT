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
    var profileImages: [String: NSImage] = [:]
    var emails: [String: String] = [:]
    private let vault = Vault()
    private let session = CodexSession()
    private let index: URL

    init(index: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.index = index ?? support.appendingPathComponent("SwitchGPT/accounts.json")
        do {
            if index == nil { try Self.migrateAccountIndex(in: support) }
            if FileManager.default.fileExists(atPath: self.index.path) {
                accounts = try JSONDecoder().decode([Account].self, from: Data(contentsOf: self.index))
            }
            refresh()
        } catch { message = L10n.text("list_read") }
    }
    static func migrateAccountIndex(in support: URL) throws {
        let destination = support.appendingPathComponent("SwitchGPT/accounts.json")
        // Read the pre-rename location once; retain the original as a recovery copy.
        let previous = support.appendingPathComponent("CodexAccountSwitch/accounts.json")
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path), files.fileExists(atPath: previous.path) else { return }
        let data = try Data(contentsOf: previous)
        _ = try JSONDecoder().decode([Account].self, from: data)
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.copyItem(at: previous, to: destination)
    }
    func refresh() { currentID = try? session.read().id }
    func email(_ account: Account) -> String { emails[account.id] ?? account.name }
    func displayName(_ account: Account) -> String { account.nickname ?? email(account) }
    @discardableResult
    func rename(_ account: Account, to name: String) -> Bool {
        guard !busy, let position = accounts.firstIndex(where: { $0.id == account.id }) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = accounts[position].nickname
        accounts[position].nickname = trimmed.isEmpty ? nil : trimmed
        do { try persist(); return true }
        catch { accounts[position].nickname = previous; message = L10n.text("rename_failed"); return false }
    }
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
                if let photoData = try? await UsageClient().fetchProfileImage(credential) {
                    profileImages[account.id] = NSImage(data: photoData)
                } else { profileImages[account.id] = nil }
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
        let nickname = accounts.first { $0.id == credential.id || $0.id == credential.id.components(separatedBy: "|")[0] }?.nickname
        accounts.removeAll { $0.id == credential.id || $0.id == credential.id.components(separatedBy: "|")[0] }
        accounts.append(Account(id: credential.id, name: label, savedAt: .now, nickname: nickname))
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
