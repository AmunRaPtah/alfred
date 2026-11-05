import SwiftUI

/// Drafts Alfred wants to send, waiting on the owner (PROTOCOL.md "Outbox").
/// Approve really sends the email, so it always goes through a confirmation
/// dialog first; Reject just discards the draft.
struct OutboxView: View {
    @Environment(AppStore.self) private var store
    @State private var items: [OutboxItem] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var notice: String?
    @State private var busyId: String?
    @State private var confirming: OutboxItem?

    var body: some View {
        List {
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(AlfredPalette.caution)
                    .listRowBackground(AlfredPalette.slate.opacity(0.5))
            }
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(AlfredPalette.signal)
                    .listRowBackground(AlfredPalette.slate.opacity(0.5))
            }
            if items.isEmpty {
                Group {
                    if loaded {
                        ButlerEmptyState(text: "No drafts awaiting approval.")
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(items) { item in
                    OutboxRow(item: item, busy: busyId == item.id,
                              onApprove: { confirming = item },
                              onReject: { Task { await reject(item) } })
                        .listRowBackground(AlfredPalette.slate.opacity(0.5))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AlfredBackground())
        .listStyle(.insetGrouped)
        .refreshable { await load() }
        .navigationTitle("Outbox")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog(
            "Send this email?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { item in
            Button("Send to \(item.recipient)") { Task { await approve(item) } }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("Alfred will send \"\(item.subject)\" from your Gmail right away. This can't be undone.")
        }
    }

    private func load() async {
        do {
            items = try await store.api.outbox(status: "pending")
            error = nil
        } catch {
            self.error = APIClient.describe(error)
        }
        loaded = true
    }

    private func approve(_ item: OutboxItem) async {
        busyId = item.id
        defer { busyId = nil }
        notice = nil
        do {
            let result = try await store.api.approveOutbox(id: item.id)
            if let result, result.status == "failed" {
                error = "Sending failed: \(result.error ?? "unknown error")"
                Haptics.warning()
            } else {
                error = nil
                notice = "Sent to \(item.recipient)."
                Haptics.success()
            }
        } catch {
            self.error = describe(error, action: "approve")
            Haptics.warning()
        }
        await load()
    }

    private func reject(_ item: OutboxItem) async {
        busyId = item.id
        defer { busyId = nil }
        notice = nil
        do {
            try await store.api.rejectOutbox(id: item.id)
            error = nil
            notice = "Draft discarded."
            Haptics.tap()
        } catch {
            self.error = describe(error, action: "reject")
            Haptics.warning()
        }
        await load()
    }

    private func describe(_ error: Error, action: String) -> String {
        if let e = error as? APIError {
            switch e {
            case .http(403, let body):
                return "alfredd refused to \(action) this draft (403). \(body)"
            case .http(409, let body):
                return "This draft was already handled. \(body)"
            default:
                break
            }
        }
        return APIClient.describe(error)
    }
}

private struct OutboxRow: View {
    var item: OutboxItem
    var busy: Bool
    var onApprove: () -> Void
    var onReject: () -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.recipient.isEmpty ? "(no recipient)" : item.recipient)
                    .font(AlfredFont.ui(13, weight: .medium))
                    .foregroundStyle(AlfredPalette.mist)
                    .lineLimit(1)
                Spacer()
                if let created = item.created {
                    Text(RelativeTime.string(created))
                        .font(AlfredFont.caption)
                        .foregroundStyle(AlfredPalette.mist)
                }
            }
            Text(item.subject.isEmpty ? "(no subject)" : item.subject)
                .font(AlfredFont.heading)
                .foregroundStyle(AlfredPalette.parchment)
            Text(item.body)
                .font(AlfredFont.body)
                .foregroundStyle(AlfredPalette.parchment.opacity(0.85))
                .lineLimit(expanded ? nil : 3)
                .textSelection(.enabled)
            if !item.attachments.isEmpty {
                Label(item.attachments.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "),
                      systemImage: "paperclip")
                    .font(AlfredFont.caption)
                    .foregroundStyle(AlfredPalette.mist)
            }
            HStack(spacing: 12) {
                Button(expanded ? "Show less" : "Show full email") {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                }
                .buttonStyle(.borderless)
                .font(AlfredFont.caption)
                Spacer()
                if busy {
                    ProgressView()
                } else {
                    Button("Reject", role: .destructive, action: onReject)
                        .buttonStyle(.bordered)
                    Button("Approve", action: onApprove)
                        .buttonStyle(.borderedProminent)
                        .tint(AlfredPalette.brass)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
