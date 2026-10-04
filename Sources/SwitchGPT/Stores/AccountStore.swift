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
    var claudeUsage: ClaudeAccountUsage?
    var claudeUsageError: String?
    var claudeNickname: String?
    private let vault: any CredentialVault
    private let session: CodexSession
    private let usageClient: UsageClient
    private let claudeUsageClient: ClaudeUsageClient
    private let credentialRefresher: CredentialRefresher
    private let resetLedger: ResetCreditLedger
    private let index: URL
    private var relay: ModelRelay?
    @ObservationIgnored private var lastCompletedEventAt: Date?
    private(set) var routingCredentials: [String: RelayCredentials] = [:]
    @ObservationIgnored private lazy var router = AccountRouter { [weak self] credentials in
        Task { @MainActor [weak self] in self?.didAutomaticallySwitch(credentials) }
    }
    private var selectionURL: URL { index.deletingLastPathComponent().appendingPathComponent("routing-selection.json") }
    private var preferencesURL: URL { index.deletingLastPathComponent().appendingPathComponent("routing-preferences.json") }
    private var claudeAccountURL: URL { index.deletingLastPathComponent().appendingPathComponent("claude-account.json") }

    init(index: URL? = nil, usageClient: UsageClient = UsageClient(), claudeUsageClient: ClaudeUsageClient = ClaudeUsageClient(), session: CodexSession = CodexSession(), vault: any CredentialVault = Vault(), tokenRefreshClient: TokenRefreshClient = TokenRefreshClient()) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.index = index ?? support.appendingPathComponent("SwitchGPT/accounts.json")
        self.session = session
        self.vault = vault
        self.credentialRefresher = CredentialRefresher(client: tokenRefreshClient)
        self.usageClient = usageClient
        self.claudeUsageClient = claudeUsageClient
        self.resetLedger = ResetCreditLedger(file: self.index.deletingLastPathComponent().appendingPathComponent("reset-credit-attempts.json"))
        self.lastCompletedEventAt = nil
        do {
            if index == nil { try Self.migrateAccountIndex(in: support) }
            if FileManager.default.fileExists(atPath: self.index.path) {
                accounts = try JSONDecoder().decode([Account].self, from: Data(contentsOf: self.index))
            }
            if let data = try? Data(contentsOf: preferencesURL),
               let saved = try? JSONDecoder().decode(RoutingPreferences.self, from: data) {
                routingPreferences = saved
            }
            if let data = try? Data(contentsOf: claudeAccountURL),
               let saved = try? JSONDecoder().decode(ClaudeAccountSettings.self, from: data) {
                claudeNickname = saved.nickname
            }
            let events = self.index.deletingLastPathComponent().appendingPathComponent("relay-events.jsonl")
            if let lines = try? String(contentsOf: events, encoding: .utf8).split(separator: "\n") {
                let completed = lines.reversed().lazy.compactMap { try? JSONDecoder().decode(RelayEvent.self, from: Data($0.utf8)) }
                    .first { $0.completed && $0.status == 200 }
                lastRequest = completed
                lastCompletedEventAt = completed.map { $0.finishedAt ?? $0.date }
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
    var desktopAccount: Account? {
        guard let desktopID else { return nil }
        // The same account can carry a different login subject (for example Apple vs. email sign-in).
        return accounts.first { $0.id == desktopID }
            ?? accounts.first { $0.id.components(separatedBy: "|")[0] == desktopID.components(separatedBy: "|")[0] }
    }
    var desktopName: String {
        desktopAccount.map { displayName($0) } ?? L10n.text("desktop_account")
    }
    func restoreRouting() async {
        guard let data = try? Data(contentsOf: selectionURL),
              let id = try? JSONDecoder().decode(String.self, from: data),
              let account = accounts.first(where: { $0.id == id }) else { return }
        await switchTo(account)
    }
    func email(_ account: Account) -> String { emails[account.id] ?? account.name }
    func displayName(_ account: Account) -> String { account.nickname ?? email(account) }
    var claudeEmail: String { claudeUsage?.email ?? "Claude Code" }
    var claudeDisplayName: String { claudeNickname ?? claudeEmail }
    @discardableResult
    func renameClaude(to name: String) -> Bool {
        guard !busy else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = ClaudeAccountSettings(nickname: trimmed.isEmpty ? nil : trimmed)
        do {
            try FileManager.default.createDirectory(at: claudeAccountURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(settings).write(to: claudeAccountURL, options: .atomic)
            claudeNickname = settings.nickname
            return true
        } catch { message = L10n.text("rename_failed"); return false }
    }
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
        // The Claude Code account is independent of the ChatGPT accounts; query it alongside them.
        let claudeClient = claudeAvailable ? claudeUsageClient : nil
        async let claudeResult = claudeClient?.load()
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
        switch await claudeResult {
        case .success(let usage): claudeUsage = usage; claudeUsageError = nil
        case .failure(let error): claudeUsage = nil; claudeUsageError = error.localizedDescription
        case nil: claudeUsage = nil; claudeUsageError = nil
        }
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

    /// Expiry dates of the account's unused reset credits, earliest first.
    func resetExpirations(_ account: Account) -> [Date] {
        resetDetails[account.id]?.availableCredits.compactMap(\.expiration) ?? []
    }

    func canUseReset(_ account: Account) -> Bool { resetBlock(account) == nil }

    /// A pending request can always be checked; otherwise a reset needs a fresh, error-free usage read.
    func resetBlock(_ account: Account) -> ResetBlock? {
        guard !busy, !loadingUsage, accounts.contains(where: { $0.id == account.id }) else { return .busy }
        guard resetLedger.readable else { return .storage }
        if hasPendingReset(account) { return nil }
        guard usageErrors[account.id] == nil,
              Date.now.timeIntervalSince(usageUpdatedAt[account.id] ?? .distantPast) <= 120,
              let credits = usages[account.id]?.rateLimitResetCredits else { return .stale }
        if credits.availableCount <= 0 { return .noCredit }
        return credits.canUse ? nil : .notApplicable
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
            var detail: String?
            switch receipt.result.code {
            case .reset: key = "reset_success"
            case .alreadyRedeemed: key = "reset_already_redeemed"
            case .nothingToReset: key = "reset_not_applicable"; detail = L10n.text("reset_not_applicable_detail")
            case .noCredit: key = "reset_no_credit"
            }
            let used = receipt.result.code == .reset || receipt.result.code == .alreadyRedeemed
            if !receipt.reconciled {
                detail = L10n.text("reset_followup_pending")
            } else if used {
                detail = L10n.format("reset_success_detail", displayName(account),
                                     usages[account.id]?.rateLimitResetCredits?.availableCount ?? 0)
            }
            return ResetCreditMessage(text: L10n.text(key), detail: detail, succeeded: used && receipt.reconciled)
        } catch {
            if hasPendingReset(account) { return ResetCreditMessage(text: L10n.text("reset_uncertain"), detail: nil, succeeded: false) }
            return ResetCreditMessage(text: L10n.text("reset_failed"), detail: error.localizedDescription, succeeded: false)
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

    var claudeAvailable: Bool { ClaudeCLI.locate() != nil }

    func shutdown() { relay?.claude.shutdown() }
    var desktopRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty }

    /// Returns true when the setting changed. Codex keeps its model list until it refetches the catalog.
    @discardableResult
    func setClaudeEnabled(_ enabled: Bool) -> Bool {
        guard routingPreferences.claudeEnabled != enabled else { return false }
        var updated = routingPreferences
        updated.claudeEnabled = enabled
        do {
            try savePreferences(updated)
            relay?.claude.setEnabled(enabled)
            session.clearModelCache()
            if enabled && RoutingConfiguration(home: session.home).overridesCatalog { message = L10n.text("claude_catalog_override") }
            return true
        } catch { message = error.localizedDescription; return false }
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
            let completedAt = event.finishedAt ?? event.date
            if lastCompletedEventAt == nil || completedAt >= lastCompletedEventAt! {
                lastCompletedEventAt = completedAt
            }
        }
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

    func restartDesktop(clearingModelCache: Bool = false) async {
        guard !busy else { return }
        busy = true
        message = ""
        defer { busy = false; refresh() }
        do {
            let app = try session.appURL()
            // The restarted picker lists what Claude Code offers now, not a list from before an update.
            if clearingModelCache, routingPreferences.claudeEnabled, let relay { await relay.claude.models.refreshed() }
            try await session.stop(app: app)
            if clearingModelCache { session.clearModelCache() }
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
    private func persist(_ saved: [Account]? = nil) throws {
        try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved ?? accounts).write(to: index, options: .atomic)
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
        guard accounts.contains(where: { $0.id == account.id }) else { return }
        guard router.beginRemoving(RelayCredentials.fingerprint(account.id)) else {
            message = L10n.text("routing_delete_active"); return
        }
        defer { updateRouter() }
        let previous = accounts
        let updated = accounts.filter { $0.id != account.id }
        do {
            // A failed index write must never delete usable authentication.
            try persist(updated)
            do { try vault.remove(account.id) }
            catch {
                let deletionError = error
                do { try persist(previous) }
                catch { message = L10n.text("delete_rollback_failed"); return }
                throw deletionError
            }
            accounts = updated
            routingCredentials.removeValue(forKey: account.id)
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
            let models = support.appendingPathComponent("claude-models.json")
            let activeRelay = relay ?? ModelRelay(desktopAuth: session.auth, eventURL: support.appendingPathComponent("relay-events.jsonl"),
                                                 router: router,
                                                 claude: ClaudeExecutor(models: ClaudeModelCatalog(file: models, discover: ClaudeModelDiscovery.run)),
                                                 didRecord: { [weak self] event in
                Task { @MainActor [weak self] in self?.received(event) }
            })
            let isStarting = relay == nil
            if isStarting {
                activeRelay.select(credentials)
                activeRelay.claude.setEnabled(routingPreferences.claudeEnabled)
            }
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
