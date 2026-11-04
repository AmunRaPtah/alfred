import SwiftUI

/// A record of what Alfred has already dealt with: finished conversations
/// and the pushes/reminders he's shown. Not Helm's SessionsListView (which
/// is Ask Alfred's job here); Inbox is a history, not a picker to start chats.
struct InboxView: View {
    @Environment(AppStore.self) private var store
    @State private var nav = Navigator.shared
    @State private var log = NotificationLog.shared

    private var finished: [Session] {
        store.sessions.filter { $0.state == .exited }.sorted { $0.updatedDate > $1.updatedDate }
    }

    var body: some View {
        NavigationStack {
            List {
                if !log.entries.isEmpty {
                    Section("Notifications") {
                        ForEach(log.entries) { entry in
                            Button {
                                if let sid = entry.sessionId { nav.openSession(sid) }
                            } label: {
                                NotificationRow(entry: entry)
                            }
                            .listRowBackground(AlfredPalette.slate.opacity(0.5))
                        }
                    }
                }
                Section("Finished conversations") {
                    if finished.isEmpty {
                        ButlerEmptyState(text: "Nothing finished yet.")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(finished) { s in
                            Button { nav.openSession(s.id) } label: {
                                FinishedRow(session: s)
                            }
                            .listRowBackground(AlfredPalette.slate.opacity(0.5))
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AlfredBackground())
            .listStyle(.insetGrouped)
            .refreshable { await store.refresh() }
            .navigationTitle("Inbox")
            .toolbar {
                if !log.entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear") { log.clear() }
                    }
                }
            }
        }
        .task { await store.refresh() }
    }
}

private struct NotificationRow: View {
    let entry: NotificationEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.fill")
                .foregroundStyle(AlfredPalette.brass)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? "Alfred" : entry.title)
                    .font(AlfredFont.ui(15, weight: .medium))
                    .foregroundStyle(AlfredPalette.parchment)
                if !entry.body.isEmpty {
                    Text(entry.body)
                        .font(AlfredFont.caption)
                        .foregroundStyle(AlfredPalette.mist)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(RelativeTime.string(entry.receivedAt))
                .font(AlfredFont.caption)
                .foregroundStyle(AlfredPalette.mist)
        }
        .padding(.vertical, 2)
    }
}

private struct FinishedRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.zzz")
                .foregroundStyle(AlfredPalette.mist)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(AlfredFont.ui(15, weight: .medium))
                    .foregroundStyle(AlfredPalette.parchment)
                    .lineLimit(1)
                if !session.cwd.isEmpty {
                    Text(session.cwdBasename)
                        .font(AlfredFont.caption)
                        .foregroundStyle(AlfredPalette.mist)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(RelativeTime.string(session.updatedDate))
                .font(AlfredFont.caption)
                .foregroundStyle(AlfredPalette.mist)
        }
        .padding(.vertical, 2)
    }
}
