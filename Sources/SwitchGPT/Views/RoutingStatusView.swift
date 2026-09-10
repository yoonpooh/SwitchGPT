import SwiftUI

struct RoutingStatusView: View {
    var store: AccountStore
    var restart: () -> Void

    var body: some View {
        if let account = store.selectedAccount {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if store.needsRestart {
                        Label(L10n.text("routing_pending"), systemImage: "clock").foregroundStyle(.orange)
                    } else { Text(L10n.text("routing_next")).foregroundStyle(.secondary) }
                    Spacer()
                    if store.routingPreferences.automatic {
                        TimelineView(.periodic(from: .now, by: 5)) { context in
                            let switched = store.lastAutomaticSwitch.map { context.date.timeIntervalSince($0) < 30 } ?? false
                            Label(L10n.text(switched ? "routing_auto_switched" : "routing_auto_badge"),
                                  systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(switched ? Color.accentColor : .secondary)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(switched ? Color.accentColor.opacity(0.1) : .clear, in: Capsule())
                                .fixedSize()
                                .help(L10n.text(switched ? "routing_auto_changed" : "routing_auto_help"))
                        }
                    }
                }.font(.caption.weight(.medium))
                HStack(spacing: 9) {
                    AccountAvatar(store: store, account: account, size: 32)
                    Text(store.displayName(account)).font(.system(size: 17, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    if let plan = store.usages[account.id]?.planType { PlanBadge(plan: plan) }
                    Spacer(minLength: 0)
                }
                if store.needsRestart {
                    Text(L10n.text("routing_restart_hint")).font(.caption).foregroundStyle(.secondary)
                    Button(action: restart) {
                        Text(L10n.text("routing_restart_action")).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }.buttonStyle(.borderedProminent).disabled(store.busy)
                    Text(L10n.text("routing_once")).font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                } else {
                    Divider()
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        HStack(spacing: 7) {
                            Text(L10n.text("routing_recent")).font(.caption).foregroundStyle(.secondary)
                            if let recent = store.lastRequestAccount, let event = store.lastRequest {
                                Text(store.displayName(recent)).font(.caption.weight(.medium)).lineLimit(1)
                                Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                                Spacer(minLength: 0)
                                Text(relativeDate(event.finishedAt ?? event.date, now: context.date))
                                    .font(.caption2).foregroundStyle(.secondary).fixedSize()
                            } else {
                                Spacer()
                                Text(L10n.text("routing_no_request")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !store.routingPreferences.desktopVerified {
                        Label(L10n.text("routing_waiting"), systemImage: "clock")
                            .font(.caption2).foregroundStyle(.secondary)
                            .help(L10n.text("routing_waiting_help"))
                    }
                    if store.selectedExhausted {
                        Label(L10n.text(store.routingPreferences.automatic ? "routing_no_available" : "routing_exhausted"),
                              systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }.padding(14)
                .background((store.needsRestart ? Color.orange : Color.accentColor).opacity(0.065),
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder((store.needsRestart ? Color.orange : Color.accentColor).opacity(0.18), lineWidth: 0.7)
                }
        } else {
            Text(L10n.text("routing_choose_short")).font(.callout).foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
    }

    private func relativeDate(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return L10n.text("routing_just_now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L10n.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
