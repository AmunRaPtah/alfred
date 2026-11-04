import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var nav = Navigator.shared
    @State private var inbox = FileInbox.shared
    @State private var attaching = false

    var body: some View {
        Group {
            if store.config.isConfigured {
                TabView(selection: Binding(get: { nav.selectedTab }, set: { nav.selectedTab = $0 })) {
                    TodayView()
                        .tabItem { Label("Today", systemImage: "sun.horizon") }
                        .tag(AppTab.today)
                    AskAlfredView()
                        .tabItem { Label("Ask Alfred", systemImage: "quote.bubble") }
                        .tag(AppTab.askAlfred)
                    InboxView()
                        .tabItem { Label("Inbox", systemImage: "tray") }
                        .tag(AppTab.inbox)
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(AppTab.settings)
                }
                .tint(AlfredPalette.brass)
                // Files handed to Alfred by another app ("Open in Alfred"): alfredd has
                // no /box, so each one is attached to the current primary conversation
                // via /upload instead, then the composer is brought to the front.
                .onChange(of: inbox.pending.count) { _, n in if n > 0 { attachPending() } }
                .onAppear { if !inbox.pending.isEmpty { attachPending() } }
            } else {
                NavigationStack {
                    SettingsView(isOnboarding: true)
                }
                .tint(AlfredPalette.brass)
            }
        }
        .background(AlfredBackground())
    }

    private func attachPending() {
        guard !attaching else { return }
        attaching = true
        Task {
            defer { attaching = false }
            guard let chat = await store.primaryChat() else { return }
            for file in inbox.pending {
                await chat.upload(data: file.data, filename: file.filename, mimeType: file.mimeType)
            }
            inbox.pending.removeAll()
            nav.openSession(chat.session.id)
        }
    }
}
