import SwiftUI

/// Alfred's primary conversation screen. Unlike Helm's sessions-list-plus-
/// chat, there is no list here: Ask Alfred always shows one ongoing
/// conversation (AppStore.primaryChat()), with older ones reachable from a
/// toolbar sheet rather than a front-and-center list.
struct AskAlfredView: View {
    @Environment(AppStore.self) private var store
    @State private var nav = Navigator.shared
    @State private var chat: ChatModel?
    @State private var loadError: String?
    @State private var showOlder = false
    @State private var showModels = false
    @State private var renaming = false
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            Group {
                if let chat {
                    ThreadView(model: chat)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Alfred couldn't be reached", systemImage: "exclamationmark.bubble")
                    } description: {
                        Text(loadError)
                    }
                } else {
                    ProgressView().tint(AlfredPalette.brass)
                }
            }
            .background(AlfredBackground())
            .navigationTitle(chat?.session.displayTitle ?? "Ask Alfred")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { brainBadge }
                ToolbarItem(placement: .topBarTrailing) { menu }
            }
        }
        .task {
            await load()
            await store.refreshBrains()
        }
        .onChange(of: nav.pendingSessionId) { _, id in
            guard let id else { return }
            nav.pendingSessionId = nil
            Task { await open(id) }
        }
        .sheet(isPresented: $showOlder) {
            OlderThreadsView { id in
                showOlder = false
                Task { await open(id) }
            }
        }
        .sheet(isPresented: $showModels) { ModelsSheet() }
        .alert("Name this conversation", isPresented: $renaming) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard let chat else { return }
                let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                Task {
                    do {
                        let renamed = try await store.api.rename(chat.session.id, title: t)
                        store.upsert(renamed)
                        chat.mergeSession(renamed)
                    } catch {
                        chat.banner = APIClient.describe(error)
                    }
                }
            }
        }
    }

    private var menu: some View {
        Menu {
            Button {
                renameText = chat?.session.title ?? ""
                renaming = true
            } label: { Label("Rename", systemImage: "pencil") }
            .disabled(chat == nil)
            Menu {
                ForEach(store.brainCatalog.brains) { b in
                    Button {
                        Task {
                            chat = await store.startNewPrimary(brain: b.id == store.brainCatalog.defaultId ? nil : b.id)
                        }
                    } label: {
                        Label("\(b.label) · \(b.statusLabel)", systemImage: b.statusIcon)
                    }
                }
            } label: { Label("New conversation", systemImage: "square.and.pencil") }
            Button { showOlder = true } label: { Label("Older conversations", systemImage: "clock.arrow.circlepath") }
            Button { showModels = true } label: { Label("Models", systemImage: "cpu") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    /// Which brain the current thread runs on; tapping it opens Models.
    @ViewBuilder
    private var brainBadge: some View {
        if let session = chat?.session {
            let b = store.brainCatalog.brain(session.brain)
            Button { showModels = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                    Text(b?.short ?? session.brain ?? "Sonnet")
                }
                .font(AlfredFont.caption)
                .foregroundStyle(AlfredPalette.brass)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().stroke(AlfredPalette.brass.opacity(0.5)))
            }
            .accessibilityLabel("Model: \(b?.label ?? session.brain ?? "default")")
        }
    }

    private func load() async {
        chat = await store.primaryChat()
        if chat == nil { loadError = store.listError }
    }

    private func open(_ id: String) async {
        if let s = store.session(id) {
            store.switchPrimary(to: id)
            chat = store.chat(for: s)
        } else {
            do {
                let s = try await store.api.session(id)
                store.upsert(s)
                store.switchPrimary(to: id)
                chat = store.chat(for: s)
            } catch {
                loadError = APIClient.describe(error)
            }
        }
    }
}
