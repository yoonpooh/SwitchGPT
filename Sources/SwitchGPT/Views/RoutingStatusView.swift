import SwiftUI

struct RoutingStatusView: View {
    var store: AccountStore
    var restart: () -> Void

    var body: some View {
        if store.selectedAccount != nil {
            if store.needsRestart {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.text("routing_pending"), systemImage: "clock")
                        .font(.caption.weight(.medium)).foregroundStyle(.orange)
                    Text(L10n.text("routing_restart_hint")).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("routing_restart_action"), action: restart)
                        .buttonStyle(.borderedProminent).disabled(store.busy)
                        .help(L10n.text("routing_once"))
                }
            } else if store.selectedExhausted {
                Label(L10n.text(store.routingPreferences.automatic ? "routing_no_available" : "routing_exhausted"),
                      systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        } else if !store.accounts.isEmpty {
            Text(L10n.text("routing_choose_short")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
