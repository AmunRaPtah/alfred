import SwiftUI

/// Alfred's own message rendering: no bubbles-on-a-background like Helm's
/// chat. The user's words sit in a quiet brass-edged card on the right;
/// Alfred's own words sit flush left, unboxed, as if spoken rather than
/// messaged.

struct UserTurn: View {
    let text: String
    let attachments: [String]
    var dimmed = false

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty {
                    ForEach(attachments, id: \.self) { a in
                        Label((a as NSString).lastPathComponent, systemImage: "paperclip")
                            .font(AlfredFont.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundStyle(AlfredPalette.parchment)
                            .background(AlfredPalette.slate.opacity(0.8), in: Capsule())
                    }
                }
                if !text.isEmpty {
                    Text(InlineText.attributed(text))
                        .font(AlfredFont.body)
                        .foregroundStyle(AlfredPalette.parchment)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(AlfredPalette.brass.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(AlfredPalette.brass.opacity(0.3), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .opacity(dimmed ? 0.55 : 1)
        }
    }
}

struct AlfredTurn: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "suit.club.fill")
                .font(.system(size: 11))
                .foregroundStyle(AlfredPalette.brass)
                .padding(.top, 5)
            MarkdownView(text: text)
                .padding(.vertical, 2)
        }
    }
}

struct PendingTurn: View {
    let message: PendingMessage
    var onRetry: () -> Void
    var onDiscard: () -> Void
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            UserTurn(text: message.text, attachments: message.attachments, dimmed: true)
            if message.failed {
                HStack(spacing: 12) {
                    Text("Not delivered").foregroundStyle(AlfredPalette.caution)
                    Button("Retry", action: onRetry)
                    Button("Discard", role: .destructive, action: onDiscard)
                }
                .font(AlfredFont.caption)
                .buttonStyle(.borderless)
            } else if message.queueId != nil {
                HStack(spacing: 12) {
                    Label("Waiting", systemImage: "clock").foregroundStyle(AlfredPalette.mist)
                    Button("Cancel", role: .destructive, action: onCancel)
                }
                .font(AlfredFont.caption)
                .buttonStyle(.borderless)
            } else {
                Text("Sending\u{2026}").font(AlfredFont.caption).foregroundStyle(AlfredPalette.mist)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct ThinkingDisclosure: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "ellipsis.bubble")
                    Text("Considering")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer()
                }
                .font(AlfredFont.caption.weight(.medium))
                .foregroundStyle(AlfredPalette.mist)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(AlfredFont.voice(14))
                    .italic()
                    .foregroundStyle(AlfredPalette.mist)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(AlfredPalette.brass.opacity(0.3)).frame(width: 2)
                    }
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A single tool step, shown as a quiet collapsed line (Alfred's errand, not
/// a developer console). Expands to the same detail Helm shows.
struct ErrandStep: View {
    let call: ToolCallItem
    let isLive: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    statusIcon
                    Text(ErrandSummary.label(call.name))
                        .font(AlfredFont.ui(13, weight: .medium))
                        .foregroundStyle(call.isError ? AlfredPalette.caution : AlfredPalette.parchment)
                    Text(ErrandSummary.oneLine(call))
                        .font(AlfredFont.ui(13))
                        .foregroundStyle(AlfredPalette.mist)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AlfredPalette.mist)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().overlay(AlfredPalette.brass.opacity(0.2))
                VStack(alignment: .leading, spacing: 10) {
                    if !call.input.isEmpty { section("Asked", call.input) }
                    if let out = call.output {
                        section(call.isError ? "Trouble" : "Found", out.isEmpty ? "(nothing returned)" : out)
                    }
                }
                .padding(12)
            }
        }
        .background(call.isError ? AlfredPalette.caution.opacity(0.12) : AlfredPalette.slate.opacity(0.5))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(call.isError ? AlfredPalette.caution.opacity(0.5) : AlfredPalette.brass.opacity(0.15))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var statusIcon: some View {
        if call.isError {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AlfredPalette.caution).font(.footnote)
        } else if call.output == nil && isLive {
            ProgressView().tint(AlfredPalette.brass).controlSize(.mini)
        } else {
            Image(systemName: ErrandSummary.symbol(call.name)).foregroundStyle(AlfredPalette.brass).font(.footnote)
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(AlfredFont.caption.weight(.semibold)).foregroundStyle(AlfredPalette.mist)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(body.count > 6000 ? String(body.prefix(6000)) + "\n\u{2026}" : body)
                    .font(.caption.monospaced())
                    .foregroundStyle(title == "Trouble" ? AlfredPalette.caution : AlfredPalette.parchment)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .frame(maxHeight: 280)
        }
    }
}

enum ErrandSummary {
    private static let preferredKeys = ["command", "cmd", "file_path", "path", "pattern", "query", "url", "description", "prompt"]

    static func label(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
    }

    static func oneLine(_ call: ToolCallItem) -> String {
        let input = call.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = input.data(using: .utf8), let json = JSONValue.parse(data), case .object(let o) = json {
            for k in preferredKeys {
                if let v = o[k]?.string, !v.isEmpty { return firstLine(v) }
            }
            if let first = o.sorted(by: { $0.key < $1.key }).first(where: { $0.value.string?.isEmpty == false }) {
                return firstLine(first.value.string ?? "")
            }
        }
        if !input.isEmpty { return firstLine(input) }
        return firstLine(call.output ?? "")
    }

    private static func firstLine(_ s: String) -> String {
        let line = s.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? s
        return line.trimmingCharacters(in: .whitespaces)
    }

    static func symbol(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("bash") || n.contains("shell") || n.contains("exec") || n.contains("command") { return "terminal" }
        if n.contains("edit") || n.contains("write") || n.contains("patch") { return "pencil" }
        if n.contains("read") || n.contains("view") { return "doc.text" }
        if n.contains("grep") || n.contains("glob") || n.contains("search") || n.contains("find") { return "magnifyingglass" }
        if n.contains("web") || n.contains("fetch") || n.contains("http") { return "globe" }
        if n.contains("task") || n.contains("agent") { return "person.2" }
        if n.contains("todo") { return "checklist" }
        return "wrench.and.screwdriver"
    }
}

struct NoteLine: View {
    let item: SystemItem

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(item.text)
                .multilineTextAlignment(.center)
        }
        .font(AlfredFont.caption)
        .foregroundStyle(item.style == .error ? AlfredPalette.caution : AlfredPalette.mist)
        .padding(.horizontal, item.style == .error ? 10 : 0)
        .padding(.vertical, item.style == .error ? 6 : 0)
        .background {
            if item.style == .error {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AlfredPalette.caution.opacity(0.14))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var symbol: String {
        switch item.style {
        case .info: return "info.circle"
        case .status: return "circle.dashed"
        case .usage: return "gauge.with.dots.needle.33percent"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

struct ThreadItemView: View {
    let item: ChatItem
    let isLive: Bool

    var body: some View {
        switch item.kind {
        case .user(let text, let attachments):
            UserTurn(text: text, attachments: attachments)
                .contextMenu { copyButton }
        case .assistant(let text, _):
            AlfredTurn(text: text)
                .contextMenu { copyButton }
        case .thinking(let text):
            ThinkingDisclosure(text: text)
                .contextMenu { copyButton }
        case .tool(let call):
            ErrandStep(call: call, isLive: isLive)
                .contextMenu { copyButton }
        case .system(let s):
            NoteLine(item: s)
                .contextMenu { copyButton }
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = item.copyText
            Haptics.tap()
        } label: { Label("Copy", systemImage: "doc.on.doc") }
    }
}

struct ThinkingTypingIndicator: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(AlfredPalette.brass)
                    .frame(width: 6, height: 6)
                    .opacity(animate ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: animate)
            }
        }
        .padding(.vertical, 6)
        .onAppear { animate = true }
        .accessibilityLabel("Alfred is working")
    }
}
