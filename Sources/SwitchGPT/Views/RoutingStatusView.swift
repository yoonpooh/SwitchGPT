import SwiftUI

struct RoutingStatusView: View {
    var store: AccountStore
    var restart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let decision = store.lastCompletedModelRouting {
                HStack(spacing: 5) {
                    Label(L10n.text("jev_last_route"), systemImage: "wand.and.stars")
                    Text(Self.modelRoutingSummary(decision))
                        .lineLimit(1).truncationMode(.middle)
                }
                .font(.caption).foregroundStyle(.secondary)
                .help(Self.modelRoutingSummary(decision))
            }
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

    static func modelRoutingSummary(_ decision: ModelRoutingDecision) -> String {
        "\(modelName(decision.originalModel, effort: decision.originalEffort)) → \(modelName(decision.selectedModel, effort: decision.selectedEffort))"
    }

    private static func modelName(_ model: String?, effort: String?) -> String {
        let raw = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let suffix = raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).last.map(String.init) ?? raw
        let name: String
        if suffix.isEmpty {
            name = L10n.text("jev_unknown_model")
        } else {
            name = suffix.prefix(1).uppercased() + suffix.dropFirst()
        }
        let trimmedEffort = effort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedEffort.isEmpty ? name : "\(name) \(trimmedEffort)"
    }
}
