import Foundation

/// One event from events.jsonl / the WebSocket. The raw JSON is kept so
/// unknown types and extra fields survive caching untouched. (PROTOCOL.md;
/// alfredd keeps helmd's event shape unchanged.)
struct AlfredEvent: Codable, Hashable {
    let raw: JSONValue

    init(raw: JSONValue) { self.raw = raw }

    init(from decoder: Decoder) throws { raw = try JSONValue(from: decoder) }
    func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }

    var seq: Int? { raw["seq"]?.int }
    var ts: Double? { raw["ts"]?.double }
    var type: String { raw["type"]?.string ?? "" }

    var text: String { raw["text"]?.string ?? "" }
    var msgId: String? { raw["msg_id"]?.string }
    var attachments: [String] { raw["attachments"]?.stringArray ?? [] }
    var callId: String? { raw["call_id"]?.string }
    var name: String { raw["name"]?.string ?? "tool" }
    var input: String { raw["input"]?.string ?? "" }
    var output: String { raw["output"]?.string ?? "" }
    var isError: Bool { raw["is_error"]?.bool ?? false }
    var state: String? { raw["state"]?.string }
    var detail: String? { raw["detail"]?.string }
    var inputTokens: Int? { raw["input_tokens"]?.int }
    var outputTokens: Int? { raw["output_tokens"]?.int }
    var costUSD: Double? { raw["cost_usd"]?.double }
    var queueId: String? { raw["queue_id"]?.string }
    var clientId: String? { raw["client_id"]?.string }
}
