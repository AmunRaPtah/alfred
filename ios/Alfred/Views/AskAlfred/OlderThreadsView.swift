import SwiftUI

/// A sheet of past conversations, reachable from Ask Alfred's toolbar
/// instead of being the app's front door the way Helm's SessionsListView is.
struct OlderThreadsView: View {
    var onSelect: (String) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: Session?

    var body: some View {
        NavigationStack {
            List {
                if store.sessions.isEmpty {
                    ButlerEmptyState(text: "No earlier conversations yet.")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(store.sessions) { s in
                    Button { onSelect(s.id) } label: {
                        ThreadRow(session: s)
                    }
                    .listRowBackground(AlfredPalette.slate.opacity(0.5))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { pendingDelete = s } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AlfredBackground())
            .listStyle(.plain)
            .refreshable { await store.refresh() }
            .navigationTitle("Older conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .confirmationDialog("Delete this conversation?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), titleVisibility: .visible, presenting: pendingDelete) { s in
                Button("Delete", role: .destructive) { Task { await delete(s) } }
            } message: { _ in
                Text("Ends that conversation on the server. Nothing else is affected.")
            }
            .task { await store.refresh() }
        }
    }

    private func delete(_ s: Session) async {
        try? await store.api.delete(s.id)
        await store.refresh()
    }
}

private struct ThreadRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.state == .exited ? "moon.zzz" : "bubble.left.and.text.bubble.right")
                .foregroundStyle(AlfredPalette.brass)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(AlfredFont.ui(15, weight: .medium))
                    .foregroundStyle(AlfredPalette.parchment)
                    .lineLimit(1)
                Text(RelativeTime.string(session.updatedDate))
                    .font(AlfredFont.caption)
                    .foregroundStyle(AlfredPalette.mist)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .opacity(session.state == .exited ? 0.7 : 1)
    }
}

enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func string(_ date: Date) -> String {
        let secs = Date().timeIntervalSince(date)
        if secs < 45 { return "just now" }
        if secs > 6 * 86400 { return date.formatted(.dateTime.month(.abbreviated).day()) }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
