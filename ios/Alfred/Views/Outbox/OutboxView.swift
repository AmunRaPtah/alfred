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
                OutboxBanner(text: error, systemImage: "exclamationmark.triangle", tone: AlfredPalette.caution)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
            if let notice {
                OutboxBanner(text: notice, systemImage: "checkmark.seal", tone: AlfredPalette.signal)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
            if items.isEmpty {
                Group {
                    if loaded {
                        ButlerEmptyState(text: "Your correspondence is in order.",
                                         detail: "No drafts await your approval.")
                    } else {
                        BrassDots(size: 6)
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
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AlfredBackground())
        .listStyle(.plain)
        .animation(AlfredMotion.spring, value: items.map(\.id))
        .animation(AlfredMotion.fade, value: notice)
        .animation(AlfredMotion.fade, value: error)
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
        ButlerCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Text("AWAITING APPROVAL")
                        .font(AlfredFont.label)
                        .tracking(1.4)
                        .foregroundStyle(AlfredPalette.caution)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(AlfredPalette.caution.opacity(0.13), in: Capsule())
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
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("TO")
                        .font(AlfredFont.label)
                        .tracking(1.2)
                        .foregroundStyle(AlfredPalette.brass)
                    Text(item.recipient.isEmpty ? "(no recipient)" : item.recipient)
                        .font(AlfredFont.ui(13, weight: .medium))
                        .foregroundStyle(AlfredPalette.mist)
                        .lineLimit(1)
                }
                Rectangle().fill(AlfredPalette.brassRule).frame(height: 0.5)
                Text(item.body)
                    .font(AlfredFont.voice(16))
                    .lineSpacing(2)
                    .foregroundStyle(AlfredPalette.parchment.opacity(0.88))
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
                if !item.attachments.isEmpty {
                    Label(item.attachments.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "),
                          systemImage: "paperclip")
                        .font(AlfredFont.caption)
                        .foregroundStyle(AlfredPalette.mist)
                }
                HStack(spacing: 10) {
                    Button(expanded ? "Show less" : "Read in full") {
                        withAnimation(AlfredMotion.spring) { expanded.toggle() }
                    }
                    .buttonStyle(.borderless)
                    .font(AlfredFont.ui(13, weight: .medium))
                    .foregroundStyle(AlfredPalette.brass)
                    Spacer()
                    if busy {
                        BrassDots(size: 5)
                            .padding(.vertical, 10)
                    } else {
                        Button(action: onReject) {
                            QuietCapsule(title: "Reject", tint: AlfredPalette.caution)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Reject draft")
                        Button(action: onApprove) {
                            BrassCapsule(title: "Approve", systemImage: "paperplane")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Approve and send")
                    }
                }
            }
        }
    }
}

private struct OutboxBanner: View {
    let text: String
    let systemImage: String
    let tone: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tone)
            Text(text)
                .font(AlfredFont.ui(14))
                .foregroundStyle(AlfredPalette.parchment)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tone.opacity(0.3), lineWidth: 0.75))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
