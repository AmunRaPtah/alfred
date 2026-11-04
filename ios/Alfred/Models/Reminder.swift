import Foundation

/// A reminder alfredd wants surfaced on the phone (PROTOCOL.md "Additions",
/// GET/POST/DELETE /reminders). `fireAt` is always UTC on the wire.
struct Reminder: Identifiable, Hashable {
    var id: String
    var title: String
    var body: String
    var fireAt: Date
    var sessionId: String?

    init?(json j: JSONValue) {
        guard let id = j["id"]?.string, !id.isEmpty else { return nil }
        guard let fireAtString = j["fire_at"]?.string, let date = Reminder.parse(fireAtString) else { return nil }
        self.id = id
        title = j["title"]?.string ?? ""
        body = j["body"]?.string ?? ""
        fireAt = date
        sessionId = j["session_id"]?.string
    }

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ s: String) -> Date? { plain.date(from: s) ?? fractional.date(from: s) }
}
