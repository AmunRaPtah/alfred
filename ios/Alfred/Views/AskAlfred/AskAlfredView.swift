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
                ToolbarItem(placement: .topBarTrailing) { menu }
            }
        }
        .task { await load() }
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
            Button {
                Task {
                    chat = await store.startNewPrimary()
                }
            } label: { Label("New conversation", systemImage: "square.and.pencil") }
            Button { showOlder = true } label: { Label("Older conversations", systemImage: "clock.arrow.circlepath") }
        } label: {
            Image(systemName: "ellipsis.circle")
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
