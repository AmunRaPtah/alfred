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
                    ButlerEmptyState(text: "No earlier conversations yet.",
                                     detail: "When we've spoken a while, the old letters are kept here.")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(store.sessions) { s in
                    Button {
                        Haptics.tap()
                        onSelect(s.id)
                    } label: {
                        ThreadRow(session: s)
                    }
                    .butlerRow()
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
        HStack(spacing: 14) {
            Circle()
                .fill(stateTone)
                .frame(width: 7, height: 7)
                .shadow(color: stateTone.opacity(0.6), radius: session.state == .running ? 4 : 0)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(AlfredFont.voice(16, weight: .medium))
                    .foregroundStyle(AlfredPalette.parchment)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(stateLabel.uppercased())
                        .font(AlfredFont.label)
                        .tracking(1.2)
                        .foregroundStyle(stateTone)
                    Text("\u{00B7}").foregroundStyle(AlfredPalette.mist)
                    Text(RelativeTime.string(session.updatedDate))
                        .font(AlfredFont.caption)
                        .foregroundStyle(AlfredPalette.mist)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AlfredPalette.mist.opacity(0.6))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .opacity(session.state == .exited ? 0.72 : 1)
        .accessibilityElement(children: .combine)
    }

    private var stateTone: Color {
        switch session.state {
        case .running, .starting: return AlfredPalette.signal
        case .idle: return AlfredPalette.brass
        default: return AlfredPalette.mist
        }
    }

    private var stateLabel: String {
        switch session.state {
        case .running: return "At work"
        case .starting: return "Waking"
        case .idle: return "Ready"
        case .exited: return "Resting"
        default: return "Unknown"
        }
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
