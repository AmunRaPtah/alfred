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
                    VStack(spacing: 22) {
                        ButlerEmptyState(text: "I can't reach the house just now.", detail: loadError)
                        Button {
                            Haptics.tap()
                            self.loadError = nil
                            Task { await load() }
                        } label: {
                            BrassCapsule(title: "Try again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(PressableStyle())
                    }
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 14) {
                        ClocheMark(width: 44)
                        BrassDots(size: 6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
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
                .foregroundStyle(AlfredPalette.brass)
        }
        .accessibilityLabel("Conversation options")
    }

    /// Which brain the current thread runs on; tapping it opens Models.
    @ViewBuilder
    private var brainBadge: some View {
        if let session = chat?.session {
            let b = store.brainCatalog.brain(session.brain)
            Button { showModels = true } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(AlfredPalette.brassGradient)
                        .frame(width: 5, height: 5)
                    Text((b?.short ?? session.brain ?? "Sonnet").uppercased())
                        .tracking(1.2)
                }
                .font(AlfredFont.label)
                .foregroundStyle(AlfredPalette.brass)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(AlfredPalette.surface.opacity(0.7), in: Capsule())
                .overlay(Capsule().strokeBorder(AlfredPalette.hairline, lineWidth: 0.75))
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
