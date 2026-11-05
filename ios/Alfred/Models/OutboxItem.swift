import Foundation

/// A draft awaiting the owner's approval before alfredd sends it (PROTOCOL.md
/// "Outbox"). `created`/`decided`/`sent` are epoch seconds on the wire.
struct OutboxItem: Identifiable, Hashable {
    var id: String
    var kind: String
    var recipient: String
    var subject: String
    var body: String
    var attachments: [String]
    var status: String
    var created: Date?
    var error: String?

    init?(json j: JSONValue) {
        guard let id = j["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        kind = j["kind"]?.string ?? "email"
        recipient = j["recipient"]?.string ?? j["to"]?.string ?? ""
        subject = j["subject"]?.string ?? ""
        body = j["body"]?.string ?? ""
        attachments = j["attachments"]?.stringArray ?? []
        status = j["status"]?.string ?? "pending"
        created = j["created"]?.double.map { Date(timeIntervalSince1970: $0) }
        error = j["error"]?.string
    }
}
