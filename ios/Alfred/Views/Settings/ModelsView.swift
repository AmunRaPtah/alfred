import SwiftUI

/// Models screen: every brain alfredd can route a thread to, with live status
/// from GET /brains and Start/Stop for the Kaggle-hosted ones. Polls while
/// visible; starts and stops run in the background on the server.
struct ModelsView: View {
    @Environment(AppStore.self) private var store
    @State private var loadError: String?
    @State private var busy: String?
    @State private var actionError: String?
    @State private var replaceTarget: Brain?
    /// Called before switching to a freshly created thread (sheets dismiss).
    var onOpenThread: (() -> Void)? = nil

    var body: some View {
        let catalog = store.brainCatalog
        List {
            if let loadError {
                Section {
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(AlfredPalette.caution)
                }
            }
            ForEach(["proxy", "t4", "tpu"], id: \.self) { tier in
                let rows = catalog.brains.filter { $0.tier == tier }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { row($0, catalog: catalog) }
                    } header: {
                        Text(rows[0].tierLabel)
                    } footer: {
                        Text(footer(tier, catalog: catalog))
                    }
                }
            }
            if let actionError {
                Section {
                    Text(actionError)
                        .font(.footnote)
                        .foregroundStyle(AlfredPalette.caution)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AlfredBackground())
        .refreshable { await refresh() }
        .task {
            // Poll while the screen is visible; .task cancels on disappear.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(6))
            }
        }
        .confirmationDialog(replaceTitle, isPresented: Binding(
            get: { replaceTarget != nil }, set: { if !$0 { replaceTarget = nil } }
        ), titleVisibility: .visible) {
            if let target = replaceTarget {
                Button("Replace with \(target.short)", role: .destructive) {
                    Task { await start(target, replace: true) }
                }
            }
            Button("Cancel", role: .cancel) { replaceTarget = nil }
        } message: {
            Text("The T4 session holds one model at a time. Replacing stops the current one, which interrupts any thread using it.")
        }
    }

    private var replaceTitle: String {
        let loaded = store.brainCatalog.t4Loaded.flatMap { store.brainCatalog.brain($0)?.short } ?? "another model"
        return "\(loaded) is running"
    }

    private func footer(_ tier: String, catalog: BrainCatalog) -> String {
        let base = footerBase(tier)
        let q = tier == "t4" ? catalog.quotaLine("gpu") : tier == "tpu" ? catalog.quotaLine("tpu") : nil
        return q.map { base + "\n" + $0 } ?? base
    }

    private func footerBase(_ tier: String) -> String {
        switch tier {
        case "proxy": return "Always available. New conversations use this unless you pick another model."
        case "t4": return "Free Kaggle 2x T4, one model at a time. Stops by itself after 15 idle minutes."
        default: return "Free Kaggle TPU v5e-8. Often queued for capacity."
        }
    }

    @ViewBuilder
    private func row(_ b: Brain, catalog: BrainCatalog) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(b.label).font(AlfredFont.body.weight(.semibold))
                if b.id == catalog.defaultId {
                    Text("Default")
                        .font(AlfredFont.caption)
                        .foregroundStyle(AlfredPalette.mist)
                }
                Spacer()
                Label(b.statusLabel, systemImage: b.statusIcon)
                    .font(AlfredFont.caption)
                    .foregroundStyle(color(b.status))
            }
            Text(b.note)
                .font(AlfredFont.caption)
                .foregroundStyle(AlfredPalette.mist)
            if let detail = b.detail, !detail.isEmpty {
                Text(detail)
                    .font(AlfredFont.caption)
                    .foregroundStyle(AlfredPalette.mist)
            }
            if b.controllable {
                HStack {
                    if busy == b.id {
                        ProgressView()
                    } else if b.status == .up || b.status == .starting {
                        Button("Stop", role: .destructive) { Task { await stop(b) } }
                            .buttonStyle(.bordered)
                    } else if b.status != .stopping {
                        Button("Start") { Task { await start(b, replace: false) } }
                            .buttonStyle(.borderedProminent)
                            .tint(AlfredPalette.brass)
                    }
                    Spacer()
                    Button {
                        Task {
                            if let chat = await store.startNewPrimary(brain: b.id) {
                                onOpenThread?()
                                Navigator.shared.openSession(chat.session.id)
                            }
                        }
                    } label: { Label("New thread", systemImage: "square.and.pencil") }
                        .buttonStyle(.borderless)
                        .font(AlfredFont.caption)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func color(_ s: Brain.Status) -> Color {
        switch s {
        case .up: return AlfredPalette.signal
        case .starting, .stopping: return AlfredPalette.brass
        case .down, .unknown: return AlfredPalette.mist
        }
    }

    private func refresh() async {
        guard store.config.isConfigured else { return }
        loadError = await store.refreshBrains()
    }

    private func start(_ b: Brain, replace: Bool) async {
        busy = b.id
        defer { busy = nil }
        do {
            try await store.api.startBrain(b.id, replace: replace)
            actionError = nil
            Haptics.success()
        } catch {
            if case .http(409, _)? = error as? APIError, !replace {
                replaceTarget = b
            } else {
                actionError = message(error)
            }
        }
        await refresh()
    }

    private func stop(_ b: Brain) async {
        busy = b.id
        defer { busy = nil }
        do {
            try await store.api.stopBrain(b.id)
            actionError = nil
        } catch {
            actionError = message(error)
        }
        await refresh()
    }

    /// The server's own detail beats the generic APIError text (a 409 here is
    /// about the T4 slot, not a busy session).
    private func message(_ error: Error) -> String {
        if case .http(_, let detail)? = error as? APIError, !detail.isEmpty { return detail }
        return APIClient.describe(error)
    }
}

/// ModelsView wrapped for presentation as a sheet (Settings and Ask Alfred).
struct ModelsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ModelsView(onOpenThread: { dismiss() })
                .navigationTitle("Models")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
