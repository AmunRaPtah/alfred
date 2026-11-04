import Foundation

struct ToolCallItem: Equatable {
    var name: String
    var input: String
    var output: String?
    var isError: Bool
}

struct SystemItem: Equatable {
    enum Style: Equatable { case info, status, usage, error }
    var text: String
    var style: Style
}

struct ChatItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(text: String, attachments: [String])
        case assistant(text: String, isFinal: Bool)
        case thinking(text: String)
        case tool(ToolCallItem)
        case system(SystemItem)
    }

    let id: String
    var kind: Kind
    var ts: Double?

    var copyText: String {
        switch kind {
        case .user(let t, _), .assistant(let t, _), .thinking(let t): return t
        case .tool(let c): return [c.name, c.input, c.output ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .system(let s): return s.text
        }
    }
}

/// Folds the event stream into renderable chat items. Unknown event types are
/// ignored; events are applied idempotently by seq. Pure protocol-parsing
/// plumbing, carried over from Helm unchanged except for the AlfredEvent type.
struct Transcript {
    private(set) var items: [ChatItem] = []
    private var index: [String: Int] = [:]
    private(set) var maxSeq = 0
    private(set) var lastState: SessionState?
    private(set) var stateChangedAt: Double?

    var isEmpty: Bool { items.isEmpty }

    /// Returns true if anything visible changed.
    @discardableResult
    mutating func apply(_ e: AlfredEvent) -> Bool {
        if let s = e.seq {
            if s <= maxSeq { return false }
            maxSeq = s
        }
        let fallbackId = "seq-\(e.seq ?? (items.count + 1_000_000))"

        switch e.type {
        case "user":
            append(ChatItem(id: "user-\(fallbackId)", kind: .user(text: e.text, attachments: e.attachments), ts: e.ts))

        case "assistant_delta":
            let key = "msg-\(e.msgId ?? fallbackId)"
            if let i = index[key], case .assistant(let t, let final) = items[i].kind {
                if final { return false }
                items[i].kind = .assistant(text: t + e.text, isFinal: false)
            } else {
                append(ChatItem(id: key, kind: .assistant(text: e.text, isFinal: false), ts: e.ts))
            }

        case "assistant":
            let key = "msg-\(e.msgId ?? fallbackId)"
            if let i = index[key] {
                items[i].kind = .assistant(text: e.text, isFinal: true)
            } else {
                append(ChatItem(id: key, kind: .assistant(text: e.text, isFinal: true), ts: e.ts))
            }

        case "thinking":
            let key = "think-\(e.msgId ?? fallbackId)"
            if let i = index[key], case .thinking(let t) = items[i].kind {
                // Same msg_id again: a fuller summary replaces, otherwise it's a chunk.
                items[i].kind = .thinking(text: e.text.hasPrefix(t) ? e.text : t + e.text)
            } else {
                append(ChatItem(id: key, kind: .thinking(text: e.text), ts: e.ts))
            }

        case "tool_call":
            let key = "tool-\(e.callId ?? fallbackId)"
            if let i = index[key], case .tool(var c) = items[i].kind {
                c.name = e.name
                c.input = e.input
                items[i].kind = .tool(c)
            } else {
                append(ChatItem(id: key, kind: .tool(ToolCallItem(name: e.name, input: e.input, output: nil, isError: false)), ts: e.ts))
            }

        case "tool_result":
            let key = "tool-\(e.callId ?? fallbackId)"
            if let i = index[key], case .tool(var c) = items[i].kind {
                c.output = e.output
                c.isError = e.isError
                items[i].kind = .tool(c)
            } else {
                let name = e.raw["name"]?.string ?? "tool result"
                append(ChatItem(id: key, kind: .tool(ToolCallItem(name: name, input: "", output: e.output, isError: e.isError)), ts: e.ts))
            }

        case "status":
            let state = SessionState(lenient: e.state)
            let prev = lastState
            lastState = state
            stateChangedAt = e.ts
            let detail = (e.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if state == .exited {
                append(system(fallbackId, detail.isEmpty ? "Session exited" : "Exited: \(detail)", .status, e.ts))
            } else if !detail.isEmpty {
                append(system(fallbackId, detail, .status, e.ts))
            } else {
                return prev != state
            }

        case "usage":
            append(system(fallbackId, Self.usageText(e), .usage, e.ts))

        case "error":
            append(system(fallbackId, e.text.isEmpty ? "Error" : e.text, .error, e.ts))

        case "system":
            guard !e.text.isEmpty else { return false }
            append(system(fallbackId, e.text, .info, e.ts))

        default:
            return false
        }
        return true
    }

    private func system(_ id: String, _ text: String, _ style: SystemItem.Style, _ ts: Double?) -> ChatItem {
        ChatItem(id: "sys-\(id)", kind: .system(SystemItem(text: text, style: style)), ts: ts)
    }

    private mutating func append(_ item: ChatItem) {
        if let i = index[item.id] { items[i] = item; return }
        index[item.id] = items.count
        items.append(item)
    }

    static func usageText(_ e: AlfredEvent) -> String {
        var parts: [String] = []
        if let i = e.inputTokens { parts.append("\(compact(i)) in") }
        if let o = e.outputTokens { parts.append("\(compact(o)) out") }
        if let c = e.costUSD { parts.append(String(format: "$%.4f", c)) }
        return parts.isEmpty ? "Turn complete" : parts.joined(separator: " \u{00B7} ")
    }

    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return String(n)
    }
}
