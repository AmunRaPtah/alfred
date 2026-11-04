import Foundation
import Observation

struct NotificationEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var body: String
    var sessionId: String?
    var receivedAt: Date
}

/// A short on-device history of pushes and reminders Alfred has shown, so
/// Inbox has something to display beyond finished sessions. Capped and
/// persisted to UserDefaults; this is a convenience log, not a sync source
/// of truth.
@Observable
final class NotificationLog {
    static let shared = NotificationLog()
    private static let key = "alfred.notificationLog"
    private static let cap = 50

    private(set) var entries: [NotificationEntry]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([NotificationEntry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    func record(title: String, body: String, sessionId: String?) {
        entries.insert(NotificationEntry(title: title, body: body, sessionId: sessionId, receivedAt: Date()), at: 0)
        if entries.count > Self.cap { entries.removeLast(entries.count - Self.cap) }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
