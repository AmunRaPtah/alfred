import SwiftUI

/// A record of what Alfred has already dealt with: finished conversations
/// and the pushes/reminders he's shown. Not Helm's SessionsListView (which
/// is Ask Alfred's job here); Inbox is a history, not a picker to start chats.
struct InboxView: View {
    @Environment(AppStore.self) private var store
    @State private var nav = Navigator.shared
    @State private var log = NotificationLog.shared
    @State private var pendingDrafts = 0

    private var finished: [Session] {
        store.sessions.filter { $0.state == .exited }.sorted { $0.updatedDate > $1.updatedDate }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        OutboxView()
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle().fill((pendingDrafts > 0 ? AlfredPalette.caution : AlfredPalette.brass).opacity(0.14))
                                Image(systemName: pendingDrafts > 0 ? "envelope.badge" : "envelope")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(pendingDrafts > 0 ? AlfredPalette.caution : AlfredPalette.brass)
                            }
                            .frame(width: 34, height: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Drafts awaiting approval")
                                    .font(AlfredFont.voice(16, weight: .medium))
                                    .foregroundStyle(AlfredPalette.parchment)
                                Text(pendingDrafts == 0 ? "Nothing waiting" : pendingDrafts == 1 ? "One for your eyes" : "\(pendingDrafts) for your eyes")
                                    .font(AlfredFont.caption)
                                    .foregroundStyle(AlfredPalette.mist)
                                    .contentTransition(.numericText())
                            }
                            Spacer(minLength: 4)
                            if pendingDrafts > 0 {
                                Text("\(pendingDrafts)")
                                    .font(AlfredFont.ui(12, weight: .bold))
                                    .foregroundStyle(AlfredPalette.midnight)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(AlfredPalette.brassGradient, in: Capsule())
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .butlerRow()
                } header: {
                    SectionLabel("Outbox")
                }
                if !log.entries.isEmpty {
                    Section {
                        ForEach(log.entries) { entry in
                            Button {
                                Haptics.tap()
                                if let sid = entry.sessionId { nav.openSession(sid) }
                            } label: {
                                NotificationRow(entry: entry)
                            }
                            .butlerRow()
                        }
                    } header: {
                        SectionLabel("Notes from Alfred")
                    }
                }
                Section {
                    if finished.isEmpty {
                        ButlerEmptyState(text: "Nothing finished yet.",
                                         detail: "Concluded conversations will be filed here.")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(finished) { s in
                            Button {
                                Haptics.tap()
                                nav.openSession(s.id)
                            } label: {
                                FinishedRow(session: s)
                            }
                            .butlerRow()
                        }
                    }
                } header: {
                    SectionLabel("Finished conversations")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AlfredBackground())
            .listStyle(.insetGrouped)
            .refreshable { await reload() }
            .navigationTitle("Inbox")
            .toolbar {
                if !log.entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear") {
                            Haptics.tap()
                            withAnimation(AlfredMotion.fade) { log.clear() }
                        }
                        .foregroundStyle(AlfredPalette.brass)
                    }
                }
            }
            .animation(AlfredMotion.spring, value: pendingDrafts)
        }
        .task { await reload() }
    }

    private func reload() async {
        if store.config.isConfigured, let items = try? await store.api.outbox(status: "pending") {
            pendingDrafts = items.count
        }
        await store.refresh()
    }
}

private struct NotificationRow: View {
    let entry: NotificationEntry

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(AlfredPalette.brass.opacity(0.12))
                Image(systemName: "bell")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AlfredPalette.brass)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? "Alfred" : entry.title)
                    .font(AlfredFont.voice(16, weight: .medium))
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
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct FinishedRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(AlfredPalette.mist.opacity(0.10))
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AlfredPalette.signal)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(AlfredFont.voice(16, weight: .medium))
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
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
