import SwiftUI

struct ProviderModelsView: View {
    var store: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var claude: Set<String> = []
    @State private var go: Set<String> = []
    @State private var loading = true
    @State private var loaded = false
    @State private var error: String?

    init(store: AccountStore) {
        self.store = store
        _claude = State(initialValue: Set(store.routingPreferences.claudeModelSlugs ?? ClaudeModel.newest(store.availableClaudeModels).map(\.slug)))
        _go = State(initialValue: Set(store.routingPreferences.goModelIDs ?? [OpenCodeGo.model]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("models_hint")).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if store.claudeAvailable {
                        Text("Claude Code").font(.headline)
                        ForEach(store.availableClaudeModels, id: \.slug) { model in
                            Toggle("Claude " + model.name, isOn: selection(model.slug, in: $claude))
                        }
                    }
                    if store.openCodeConfigured {
                        Divider().padding(.vertical, 6)
                        Text("OpenCode Go").font(.headline)
                        ForEach(store.goModels) { model in
                            Toggle(model.name, isOn: selection(model.id, in: $go))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(loading)
            if loading { ProgressView(L10n.text("loading")).controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button(L10n.text("models_refresh")) { Task { await load() } }.disabled(loading)
                Spacer()
                Button(L10n.text("cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("save")) {
                    if store.saveModelSelection(claude: claude, go: go) { dismiss() }
                    else { error = store.message }
                }.keyboardShortcut(.defaultAction).disabled(loading)
            }
        }.padding(20).frame(minWidth: 420, minHeight: 400)
            .task { await load() }
    }

    private func selection(_ id: String, in values: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(id) }, set: { checked in
            if checked { values.wrappedValue.insert(id) } else { values.wrappedValue.remove(id) }
        })
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do { try await store.loadProviderModels() }
        catch { self.error = error.localizedDescription }
        if !loaded {
            claude = Set(store.routingPreferences.claudeModelSlugs ?? ClaudeModel.newest(store.availableClaudeModels).map(\.slug))
            go = Set(store.routingPreferences.goModelIDs ?? [OpenCodeGo.model])
            loaded = true
        }
    }
}

struct OpenCodeUsageCard: View {
    var store: AccountStore
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "key.fill").resizable().scaledToFit().foregroundStyle(.secondary)
                .frame(width: 24, height: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("OpenCode Go").font(.caption.weight(.semibold))
                if let usage = store.openCodeUsage {
                    if let window = usage.usage.rolling {
                        UsageWindowView(label: L10n.format("hours", 5), remaining: window.remaining, resetDate: window.resetDate)
                    }
                    if let window = usage.usage.weekly {
                        UsageWindowView(label: L10n.text("weekly"), remaining: window.remaining, resetDate: window.resetDate)
                    }
                    if let window = usage.usage.monthly {
                        UsageWindowView(label: L10n.text("monthly"), remaining: window.remaining, resetDate: window.resetDate)
                    }
                }
                if let error = store.openCodeUsageError {
                    Text(error).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else if store.openCodeUsage == nil {
                    Text(L10n.text(store.loadingUsage ? "loading" : "refresh_hint")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal, 7).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
    }
}
