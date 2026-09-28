import SwiftUI

struct AccountAvatar: View {
    var store: AccountStore
    let account: Account
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let photo = store.profileImages[account.id] {
                Image(nsImage: photo).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }.frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
    }
}

struct AccountCard: View {
    var store: AccountStore
    let account: Account
    var select: () -> Void
    var useReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if store.routingPreferences.automatic {
                summary.contentShape(Rectangle()).draggable(account.id)
            } else {
                Button(action: select) { summary.contentShape(Rectangle()).draggable(account.id) }
                    .buttonStyle(.plain)
            }
            // Kept outside the selection button so its own button stays clickable; aligned with the name.
            if hasReset { resetRow.padding(.leading, 32) }
        }.padding(.horizontal, 7).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 8) {
            AccountAvatar(store: store, account: account)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(store.displayName(account)).font(.caption.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle).help(store.email(account))
                    if let plan = store.usages[account.id]?.planType { PlanBadge(plan: plan) }
                    Spacer(minLength: 0)
                }
                if let usage = store.usages[account.id] {
                    let windows = [usage.rateLimit?.primaryWindow, usage.rateLimit?.secondaryWindow].compactMap { $0 }
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                        UsageWindowView(window: window)
                    }
                    if usage.rateLimit?.primaryWindow == nil && usage.rateLimit?.secondaryWindow == nil {
                        Text(L10n.text("no_limits")).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(L10n.text(store.loadingUsage ? "loading" : "refresh_hint"))
                        .font(.caption).foregroundStyle(.secondary)
                }

            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resetCount: Int {
        store.usages[account.id]?.rateLimitResetCredits?.availableCount ?? 0
    }

    private var hasReset: Bool { resetCount > 0 || store.hasPendingReset(account) }

    /// A window is low or exhausted, so using a credit now is worthwhile.
    private var needsReset: Bool {
        guard let usage = store.usages[account.id] else { return false }
        if usage.availability() == .exhausted { return true }
        return [usage.rateLimit?.primaryWindow, usage.rateLimit?.secondaryWindow].compactMap { $0 }
            .contains { UsageBarTone.resolve(remaining: $0.remaining) != .normal }
    }

    /// Count, earliest expiry and the action stay visible; why a reset cannot be used is told in a popup on Use.
    private var resetRow: some View {
        let pending = store.hasPendingReset(account)
        let working = store.resetInProgressID == account.id
        let expiry = store.resetExpirations(account).first
        let expiringSoon = expiry.map { $0.timeIntervalSinceNow < 86_400 } ?? false
        let suggested = store.canUseReset(account) && (pending || needsReset)
        return HStack(spacing: 6) {
            Image(systemName: "arrow.counterclockwise.circle")
                .foregroundStyle(suggested ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            Text(L10n.format("reset_credits", resetCount))
                .fontWeight(.semibold).foregroundStyle(.primary).fixedSize()
            if let expiry {
                Text(expiryText(expiry))
                    .foregroundStyle(expiringSoon ? Color.orange : Color.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if working {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(L10n.text("reset_working"))
                }.fixedSize()
            } else {
                let title = L10n.text(pending ? "reset_retry" : "reset_use_button")
                Group {
                    // Draw attention to the button only when a reset would help right now.
                    if suggested { Button(title, action: useReset).buttonStyle(.borderedProminent) }
                    else { Button(title, action: useReset).buttonStyle(.bordered) }
                }
                .controlSize(.mini)
                // Stays clickable when a reset cannot be used, so the popup can say why.
                .disabled(store.resetBlock(account) == .busy)
                .help(L10n.text(pending ? "reset_retry_help" : "reset_use_help"))
                .accessibilityLabel(L10n.text(pending ? "reset_retry" : "reset_use"))
            }
        }
        .font(.system(size: 9)).foregroundStyle(.secondary)
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(suggested ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// Within a day of expiry, the remaining time reads faster than a clock time.
    private func expiryText(_ date: Date) -> String {
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 && remaining < 86_400 else { return L10n.format("reset_until", L10n.compactDate(date)) }
        var calendar = Calendar.current
        calendar.locale = L10n.locale
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.unitsStyle = .short
        formatter.allowedUnits = remaining < 3600 ? [.minute] : [.hour]
        return L10n.format("reset_time_left", formatter.string(from: max(60, remaining)) ?? "")
    }
}

enum UsageBarTone: Equatable {
    case normal
    case warning
    case critical

    static func resolve(remaining: Double) -> Self {
        if remaining < 10 { return .critical }
        if remaining < 20 { return .warning }
        return .normal
    }
}

struct UsageWindowView: View {
    let label: String
    let remaining: Double
    let resetDate: Date?

    init(window: AccountUsage.Window) {
        self.init(label: window.label, remaining: window.remaining, resetDate: window.resetDate)
    }

    init(label: String, remaining: Double, resetDate: Date?) {
        self.label = label
        self.remaining = remaining
        self.resetDate = resetDate
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let resetDate {
                    Text(L10n.compactDate(resetDate))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(L10n.format("resets_at", L10n.date(resetDate)))
                }
            }
            .frame(width: 54, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.18))
                    if remaining > 0 {
                        Capsule()
                            .fill(barTint)
                            .frame(width: geometry.size.width * remaining / 100)
                    }
                }
            }
            .frame(height: 4)
            .padding(.top, 4)
            Text("\(Int(remaining.rounded(.up)))%")
                .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
                .accessibilityLabel(L10n.format("remaining", Int(remaining.rounded(.up))))
        }
    }

    private var barTint: Color {
        switch UsageBarTone.resolve(remaining: remaining) {
        case .normal: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }
}
