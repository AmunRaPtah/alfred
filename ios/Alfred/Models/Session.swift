import Foundation

enum SessionState: String, Codable {
    case starting, idle, running, exited, unknown

    init(lenient raw: String?) {
        self = raw.flatMap { SessionState(rawValue: $0.lowercased()) } ?? .unknown
    }
}

enum PermissionMode: String, CaseIterable, Identifiable, Codable {
    case bypass, acceptEdits, `default`, plan
    var id: String { rawValue }

    var label: String {
        switch self {
        case .bypass: return "Bypass"
        case .acceptEdits: return "Accept edits"
        case .default: return "Ask"
        case .plan: return "Plan"
        }
    }
}

/// Session object from PROTOCOL.md. Only `id` is required; every other field
/// falls back to a sensible default if missing or mistyped. Unchanged from
/// helmd: alfredd keeps the same session shape, just one harness ("alfred").
struct Session: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var harness: String
    var profile: String?
    var model: String?
    /// alfred-brain choice (sonnet, khermes, kqwen, kglm, tpu); nil = default.
    var brain: String?
    var cwd: String
    var permission: String
    var state: SessionState
    var created: Double
    var updated: Double
    var lastSeq: Int
    var nativeSessionId: String?
    var tmux: String

    init?(json: JSONValue) {
        guard let id = json["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        title = json["title"]?.string ?? ""
        harness = json["harness"]?.string ?? "alfred"
        profile = json["profile"]?.string
        model = json["model"]?.string
        brain = json["brain"]?.string
        cwd = json["cwd"]?.string ?? ""
        permission = json["permission"]?.string ?? "bypass"
        state = SessionState(lenient: json["state"]?.string)
        created = json["created"]?.double ?? 0
        updated = json["updated"]?.double ?? created
        lastSeq = json["last_seq"]?.int ?? 0
        nativeSessionId = json["native_session_id"]?.string
        tmux = json["tmux"]?.string ?? "hx-\(id)"
    }

    init(from decoder: Decoder) throws {
        let v = try JSONValue(from: decoder)
        guard let s = Session(json: v) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "session without id"))
        }
        self = s
    }

    enum CodingKeys: String, CodingKey {
        case id, title, harness, profile, model, brain, cwd, permission, state, created, updated, tmux
        case lastSeq = "last_seq"
        case nativeSessionId = "native_session_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(harness, forKey: .harness)
        try c.encodeIfPresent(profile, forKey: .profile)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(brain, forKey: .brain)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(permission, forKey: .permission)
        try c.encode(state.rawValue, forKey: .state)
        try c.encode(created, forKey: .created)
        try c.encode(updated, forKey: .updated)
        try c.encode(lastSeq, forKey: .lastSeq)
        try c.encodeIfPresent(nativeSessionId, forKey: .nativeSessionId)
        try c.encode(tmux, forKey: .tmux)
    }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled conversation" : t
    }

    var cwdBasename: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    var updatedDate: Date { Date(timeIntervalSince1970: updated) }
}
