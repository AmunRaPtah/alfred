import Foundation

/// GET /push/status (PROTOCOL.md "Additions"): whether alfredd is configured
/// to send APNs pushes at all, and how many devices are registered.
struct PushStatus {
    var configured: Bool
    var teamId: String?
    var keyId: String?
    var topic: String?
    var devices: Int

    init(json j: JSONValue) {
        configured = j["configured"]?.bool ?? false
        teamId = j["team_id"]?.string
        keyId = j["key_id"]?.string
        topic = j["topic"]?.string
        devices = j["devices"]?.int ?? 0
    }
}
