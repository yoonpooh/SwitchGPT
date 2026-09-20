import SwiftUI

@MainActor @Observable
final class AccountStore {
    var accounts: [Account] = []
    var message = ""
    var addingAccount = false
    private let login = AccountLogin()
    var busy = false
    var currentID: String?
    var desktopID: String?
    var routingActive = false
    var routingPreferences = RoutingPreferences()
    var lastRequest: RelayEvent?
    var lastAutomaticSwitch: Date?
    var desktopLaunchedAt: Date?
    var selectedExhausted = false
    var resetDetails: [String: ResetCreditDetails] = [:]
    var resetInProgressID: String?
    var usages: [String: AccountUsage] = [:]
    var usageErrors: [String: String] = [:]
    var usageUpdatedAt: [String: Date] = [:]
    var loadingUsage = false
    var profileImages: [String: NSImage] = [:]
    var emails: [String: String] = [:]
    private let vault: any CredentialVault
    private let session: CodexSession
    private let usageClient: UsageClient
    private let credentialRefresher: CredentialRefresher
    private let resetLedger: ResetCreditLedger
    private let index: URL
    private var relay: ModelRelay?
    private(set) var routingCredentials: [String: RelayCredentials] = [:]
    @ObservationIgnored private lazy var router = AccountRouter { [weak self] credentials in
        Task { @MainActor [weak self] in self?.didAutomaticallySwitch(credentials) }
    }
    private var selectionURL: URL { index.deletingLastPathComponent().appendingPathComponent("routing-selection.json") }
    private var preferencesURL: URL { index.deletingLastPathComponent().appendingPathComponent("routing-preferences.json") }

    init(index: URL? = nil, usageClient: UsageClient = UsageClient(), session: CodexSession = CodexSession(), vault: any CredentialVault = Vault(), tokenRefreshClient: TokenRefreshClient = TokenRefreshClient()) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.index = index ?? support.appendingPathComponent("SwitchGPT/accounts.json")
        self.session = session
        self.vault = vault
        self.credentialRefresher = CredentialRefresher(client: tokenRefreshClient)
        self.usageClient = usageClient
        self.resetLedger = ResetCreditLedger(file: self.index.deletingLastPathComponent().appendingPathComponent("reset-credit-attempts.json"))
        do {
            if index == nil { try Self.migrateAccountIndex(in: support) }
            if FileManager.default.fileExists(atPath: self.index.path) {
                accounts = try JSONDecoder().decode([Account].self, from: Data(contentsOf: self.index))
            }
            if let data = try? Data(contentsOf: preferencesURL),
               let saved = try? JSONDecoder().decode(RoutingPreferences.self, from: data) { routingPreferences = saved }
            let events = self.index.deletingLastPathComponent().appendingPathComponent("relay-events.jsonl")
            if let lines = try? String(contentsOf: events, encoding: .utf8).split(separator: "\n") {
                lastRequest = lines.reversed().compactMap { try? JSONDecoder().decode(RelayEvent.self, from: Data($0.utf8)) }
                    .first { $0.completed && $0.status == 200 }
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
    func refresh() {
        desktopID = try? session.read().id
        desktopLaunchedAt = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first?.launchDate
    }
    var selectedAccount: Account? { accounts.first { $0.id == currentID } }
    var lastRequestAccount: Account? {
        accounts.first { RelayCredentials.fingerprint($0.id) == lastRequest?.accountFingerprint }
    }
    var needsRestart: Bool { routingPreferences.needsRestart(desktopLaunchedAt: desktopLaunchedAt) }
    var desktopName: String {
        accounts.first(where: { $0.id == desktopID }).map { displayName($0) } ?? L10n.text("desktop_account")
    }
    func restoreRouting() async {
        guard let data = try? Data(contentsOf: selectionURL),
              let id = try? JSONDecoder().decode(String.self, from: data),
              let account = accounts.first(where: { $0.id == id }) else { return }
        await switchTo(account)
    }
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
                let initial = try credentialForUsage(account)
                try updateRoutingCredential(initial, account: account)
                // Codex owns the active desktop refresh token; never rotate it independently.
                let isDesktop = (try? session.read().id) == account.id
                let queriedAt = Date.now
                let (credential, usage) = try await usageClient.fetchWithRefresh(initial, proactively: !isDesktop) { [self] previous in
                    let latest = try credentialForUsage(account)
                    if latest.data != previous.data {
                        try updateRoutingCredential(latest, account: account)
                        return latest
                    }
                    guard !isDesktop else { throw UsageAuthenticationError() }
                    return try await renewSavedCredential(previous, account: account)
                }
                usages[account.id] = usage
                try updateRoutingCredential(credential, account: account)
                emails[account.id] = credential.email ?? L10n.text("email_missing")
                if let photoData = try? await usageClient.fetchProfileImage(credential) {
                    profileImages[account.id] = NSImage(data: photoData)
                } else { profileImages[account.id] = nil }
                if (usages[account.id]?.rateLimitResetCredits?.availableCount ?? 0) > 0 {
                    resetDetails[account.id] = try? await usageClient.fetchResetCredits(credential)
                } else { resetDetails[account.id] = nil }
                usageUpdatedAt[account.id] = queriedAt
                usageErrors[account.id] = nil
            } catch {
                usageErrors[account.id] = L10n.text("unavailable_prefix") + error.localizedDescription
            }
        }
        updateRouter()
        if routingActive { _ = router.resolve() }
        selectedExhausted = router.isCurrentExhausted()
    }

    private func updateRoutingCredential(_ credential: Credential, account: Account) throws {
        let selected = try RelayCredentials(credential)
        routingCredentials[account.id] = selected
        if router.selected?.fingerprint == selected.fingerprint { relay?.select(selected) }
        updateRouter()
    }

    private func credentialForUsage(_ account: Account) throws -> Credential {
        guard accounts.contains(where: { $0.id == account.id }) else {
            throw SwitchError(message: L10n.text("account_mismatch"))
        }
        let credential: Credential
        if let desktop = try? session.read(), desktop.id == account.id {
            credential = desktop
            // Keep our saved copy in step with refreshes performed by the desktop owner.
            // Otherwise a later desktop account change could revive an already-used token.
            if (try? vault.read(account.id)) != desktop.data { try vault.save(desktop.data, id: account.id) }
        }
        else { credential = try Credential(data: vault.read(account.id)) }
        guard credential.id == account.id else { throw SwitchError(message: L10n.text("account_mismatch")) }
        return credential
    }

    private func renewSavedCredential(_ credential: Credential, account: Account) async throws -> Credential {
        try await credentialRefresher.refresh(credential, load: { [self] in
            // If this account became the desktop session, its new credential takes priority.
            guard (try? session.read().id) != account.id else { throw UsageAuthenticationError() }
            return try credentialForUsage(account)
        }, save: { [self] renewed in
            try vault.save(renewed.data, id: account.id)
            try updateRoutingCredential(renewed, account: account)
        })
    }

    func hasPendingReset(_ account: Account) -> Bool { resetLedger.hasPending(account.id) }

    func canUseReset(_ account: Account) -> Bool {
        guard !busy, !loadingUsage, resetLedger.readable, accounts.contains(where: { $0.id == account.id }) else { return false }
        if hasPendingReset(account) { return true }
        return usageErrors[account.id] == nil
            && Date.now.timeIntervalSince(usageUpdatedAt[account.id] ?? .distantPast) <= 120
            && usages[account.id]?.rateLimitResetCredits?.canUse == true
    }

    func resetHelp(_ account: Account) -> String {
        if !resetLedger.readable { return L10n.text("reset_storage_error") }
        if hasPendingReset(account) { return L10n.text("reset_retry_help") }
        if usageErrors[account.id] != nil || Date.now.timeIntervalSince(usageUpdatedAt[account.id] ?? .distantPast) > 120 {
            return L10n.text("reset_refresh_help")
        }
        guard let credits = usages[account.id]?.rateLimitResetCredits else { return L10n.text("reset_refresh_help") }
        if credits.availableCount <= 0 { return L10n.text("reset_no_credit") }
        return L10n.text(credits.canUse ? "reset_use_help" : "reset_not_applicable")
    }

    func useResetCredit(_ account: Account) async -> ResetCreditMessage? {
        guard !busy, resetLedger.readable, accounts.contains(where: { $0.id == account.id }) else { return nil }
        busy = true
        resetInProgressID = account.id
        defer { resetInProgressID = nil; busy = false }
        do {
            // A refresh may have started while the confirmation dialog was open.
            // Let that older read finish before sending a reset and refreshing its result.
            while loadingUsage { try await Task.sleep(for: .milliseconds(50)) }
            let desktop = try? session.read()
            let credential: Credential
            if let desktop, desktop.id == account.id { credential = desktop }
            else { credential = try Credential(data: vault.read(account.id)) }
            guard credential.id == account.id else { throw SwitchError(message: L10n.text("account_mismatch")) }
            let receipt = try await ResetCreditService(client: usageClient, ledger: resetLedger).redeem(credential)
            if let usage = receipt.usage, let observedAt = receipt.observedAt {
                usages[account.id] = usage
                usageUpdatedAt[account.id] = observedAt
                usageErrors[account.id] = nil
                resetDetails[account.id] = receipt.details
                routingCredentials[account.id] = try RelayCredentials(credential)
                updateRouter()
                if routingActive { _ = router.resolve() }
                selectedExhausted = router.isCurrentExhausted()
            }
            let key: String
            switch receipt.result.code {
            case .reset: key = "reset_success"
            case .alreadyRedeemed: key = "reset_already_redeemed"
            case .nothingToReset: key = "reset_not_applicable"
            case .noCredit: key = "reset_no_credit"
            }
            let used = receipt.result.code == .reset || receipt.result.code == .alreadyRedeemed
            let text = L10n.text(key) + (receipt.reconciled ? "" : " " + L10n.text("reset_followup_pending"))
            return ResetCreditMessage(text: text, succeeded: used && receipt.reconciled)
        } catch {
            let text = hasPendingReset(account) ? L10n.text("reset_uncertain") : L10n.format("reset_failed", error.localizedDescription)
            return ResetCreditMessage(text: text, succeeded: false)
        }
    }

    private func updateRouter() {
        let candidates = accounts.compactMap { account -> RoutingCandidate? in
            guard let credentials = routingCredentials[account.id] else { return nil }
            let availability = usageErrors[account.id] == nil ? usages[account.id]?.availability() ?? .unknown : .unknown
            return RoutingCandidate(credentials: credentials, availability: availability,
                                    observedAt: usageUpdatedAt[account.id] ?? .distantPast)
        }
        router.update(candidates, automatic: routingPreferences.automatic)
    }

    func setAutomatic(_ enabled: Bool) {
        var updated = routingPreferences
        updated.automatic = enabled
        do {
            try savePreferences(updated)
            updateRouter()
            if routingActive { _ = router.resolve() }
            selectedExhausted = router.isCurrentExhausted()
        } catch { message = error.localizedDescription }
    }

    private func savePreferences(_ updated: RoutingPreferences) throws {
        try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: preferencesURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferencesURL.path)
        routingPreferences = updated
    }

    private func didAutomaticallySwitch(_ credentials: RelayCredentials) {
        // A queued automatic change must never overwrite a newer manual selection.
        guard router.selected?.fingerprint == credentials.fingerprint,
              let account = accounts.first(where: { RelayCredentials.fingerprint($0.id) == credentials.fingerprint }) else { return }
        currentID = account.id
        lastAutomaticSwitch = .now
        selectedExhausted = router.isCurrentExhausted()
        do {
            try JSONEncoder().encode(account.id).write(to: selectionURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: selectionURL.path)
        } catch { message = L10n.text("routing_save_failed") }
    }

    func received(_ event: RelayEvent) {
        guard event.path == "/backend-api/codex/responses" else { return }
        selectedExhausted = router.isCurrentExhausted()
        if event.status == 200 && event.completed {
            if (event.finishedAt ?? event.date) >= (lastRequest?.finishedAt ?? lastRequest?.date ?? .distantPast) {
                lastRequest = event
            }
            if event.client == "desktop", event.date >= (routingPreferences.configuredAt ?? .distantPast),
               !routingPreferences.desktopVerified {
                var updated = routingPreferences
                updated.desktopVerified = true
                do { try savePreferences(updated) } catch { message = L10n.text("routing_save_failed") }
            }
        }
    }

    func restartDesktop() async {
        guard !busy else { return }
        busy = true
        message = ""
        defer { busy = false; refresh() }
        do {
            let app = try session.appURL()
            try await session.stop(app: app)
            try await session.launch(app)
        } catch { message = error.localizedDescription }
    }
    @discardableResult
    func reorder(_ sourceID: String, onto targetID: String) -> Bool {
        guard !busy, sourceID != targetID,
              let source = accounts.firstIndex(where: { $0.id == sourceID }),
              let target = accounts.firstIndex(where: { $0.id == targetID }) else { return false }
        let previous = accounts
        let account = accounts.remove(at: source)
        accounts.insert(account, at: target)
        do {
            try persist()
            updateRouter()
            if routingActive { _ = router.resolve() }
            selectedExhausted = router.isCurrentExhausted()
            return true
        }
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
        while loadingUsage {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { busy = false; return }
        }
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
        guard !loadingUsage, !busy else { return }
        guard account.id != currentID else { message = L10n.text("routing_delete_active"); return }
        do {
            try vault.remove(account.id)
            accounts.removeAll { $0.id == account.id }
            routingCredentials.removeValue(forKey: account.id)
            try persist()
            updateRouter()
            message = ""
        } catch { message = error.localizedDescription }
    }
    func switchTo(_ account: Account) async {
        guard !busy else { return }
        busy = true
        defer { busy = false; refresh() }
        do {
            try session.validateStore()
            let desktop = try session.read()
            let target = desktop.id == account.id ? desktop : try Credential(data: vault.read(account.id))
            guard target.id == account.id || target.id.components(separatedBy: "|")[0] == account.id else { throw SwitchError(message: L10n.text("account_mismatch")) }
            let credentials = try RelayCredentials(target)
            routingCredentials[account.id] = credentials
            let support = index.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let activeRelay = relay ?? ModelRelay(desktopAuth: session.auth, eventURL: support.appendingPathComponent("relay-events.jsonl"),
                                                 router: router, didRecord: { [weak self] event in
                Task { @MainActor [weak self] in self?.received(event) }
            })
            let isStarting = relay == nil
            if isStarting { activeRelay.select(credentials) }
            let configuration = RoutingConfiguration(home: session.home)
            var installed = false
            do {
                _ = try await activeRelay.start()
                installed = try configuration.install()
                if installed || routingPreferences.configuredAt == nil {
                    var updated = routingPreferences
                    let attributes = try? FileManager.default.attributesOfItem(atPath: session.home.appendingPathComponent("config.toml").path)
                    updated.configuredAt = installed ? .now : attributes?[.modificationDate] as? Date ?? .now
                    if installed { updated.desktopVerified = false }
                    try savePreferences(updated)
                }
                try JSONEncoder().encode(account.id).write(to: selectionURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: selectionURL.path)
                activeRelay.select(credentials)
                relay = activeRelay
                currentID = account.id
                routingActive = true
                lastAutomaticSwitch = nil
                updateRouter()
                _ = router.resolve()
                selectedExhausted = router.isCurrentExhausted()
                message = ""
            } catch {
                if installed { try? configuration.removeInstalledBlock() }
                if isStarting { activeRelay.stop() }
                throw error
            }
        } catch { message = error.localizedDescription }
    }
}
