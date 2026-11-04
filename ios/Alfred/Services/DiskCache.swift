import Foundation

/// JSON files in Application Support/Alfred so the app opens instantly offline.
enum DiskCache {
    struct EventLog: Codable {
        var lastSeq: Int
        var events: [AlfredEvent]
    }

    private static let queue = DispatchQueue(label: "org.zyco.alfred.diskcache", qos: .utility)

    private static var root: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Alfred", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("events", isDirectory: true),
                                                 withIntermediateDirectories: true)
        return dir
    }()

    private static func url(_ name: String) -> URL? { root?.appendingPathComponent(name) }
    private static func eventsURL(_ id: String) -> URL? {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return root?.appendingPathComponent("events/\(safe).json")
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL?) -> T? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL?) {
        guard let url else { return }
        queue.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    static func loadSessions() -> [Session] { load([Session].self, from: url("sessions.json")) ?? [] }
    static func saveSessions(_ s: [Session]) { save(s, to: url("sessions.json")) }

    static func loadEvents(_ id: String) -> EventLog? { load(EventLog.self, from: eventsURL(id)) }
    static func saveEvents(_ id: String, _ log: EventLog) { save(log, to: eventsURL(id)) }

    static func deleteEvents(_ id: String) {
        guard let u = eventsURL(id) else { return }
        queue.async { try? FileManager.default.removeItem(at: u) }
    }

    static func clearAll() {
        guard let r = root else { return }
        queue.async {
            try? FileManager.default.removeItem(at: r.appendingPathComponent("events"))
            try? FileManager.default.removeItem(at: r.appendingPathComponent("sessions.json"))
            try? FileManager.default.createDirectory(at: r.appendingPathComponent("events"), withIntermediateDirectories: true)
        }
    }
}
