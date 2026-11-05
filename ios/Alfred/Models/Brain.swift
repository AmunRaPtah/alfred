import Foundation

/// One model Alfred can think with (GET /brains). `sonnet` is the Kaggle
/// Benchmarks proxy and is always available; the others run on Kaggle (T4 or
/// TPU) and have to be started before they answer quickly.
struct Brain: Identifiable, Hashable {
    enum Status: String {
        case up, starting, stopping, down, unknown
    }

    var id: String
    var label: String
    var short: String
    var tier: String
    var note: String
    var status: Status
    var detail: String?
    var controllable: Bool
    var kernel: String?
    var isDefault: Bool

    init?(json j: JSONValue) {
        guard let id = j["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        label = j["label"]?.string ?? id
        short = j["short"]?.string ?? id
        tier = j["tier"]?.string ?? ""
        note = j["note"]?.string ?? ""
        status = j["status"]?.string.flatMap(Status.init(rawValue:)) ?? .unknown
        detail = j["detail"]?.string
        controllable = j["controllable"]?.bool ?? false
        kernel = j["kernel"]?.string
        isDefault = j["default"]?.bool ?? false
    }

    private init(id: String, label: String, short: String, tier: String, note: String, isDefault: Bool = false) {
        self.id = id
        self.label = label
        self.short = short
        self.tier = tier
        self.note = note
        status = .unknown
        detail = nil
        controllable = tier != "proxy"
        kernel = nil
        self.isDefault = isDefault
    }

    var tierLabel: String {
        switch tier {
        case "proxy": return "Proxy"
        case "t4": return "Kaggle T4"
        case "tpu": return "Kaggle TPU"
        default: return tier.uppercased()
        }
    }

    var statusLabel: String {
        switch status {
        case .up: return tier == "proxy" ? "Ready" : "Up"
        case .starting: return "Starting"
        case .stopping: return "Stopping"
        case .down: return "Off"
        case .unknown: return "Unknown"
        }
    }

    var statusIcon: String {
        switch status {
        case .up: return "circle.fill"
        case .starting: return "hourglass"
        case .stopping: return "stop.circle"
        case .down: return "circle"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Used before /brains has answered once (offline, older alfredd).
    static let fallback: [Brain] = [
        Brain(id: "sonnet", label: "Claude Sonnet 5", short: "Sonnet", tier: "proxy",
              note: "Default. Best quality and fast.", isDefault: true),
        Brain(id: "khermes", label: "Qwen3.6-35B-A3B", short: "khermes", tier: "t4",
              note: "Best T4 model. Cold start ~4-10 min."),
        Brain(id: "kqwen", label: "Qwen3.8-27B", short: "kqwen", tier: "t4",
              note: "Dense 27B on T4. Cold start ~4-10 min."),
        Brain(id: "kglm", label: "GLM-4.7-Flash", short: "kglm", tier: "t4",
              note: "GLM on T4. Cold start ~4-10 min."),
        Brain(id: "tpu", label: "Qwen3.5-122B (TPU)", short: "TPU", tier: "tpu",
              note: "Largest model. Cold start 60-90 min."),
    ]

    static let defaultId = "sonnet"
}

/// GET /brains as a whole: the list plus which T4 model holds the shared
/// Kaggle T4 session right now.
struct BrainCatalog {
    var brains: [Brain]
    var defaultId: String
    var t4Loaded: String?

    init(json j: JSONValue) {
        brains = (j["brains"]?.array ?? j.array ?? []).compactMap(Brain.init(json:))
        defaultId = j["default"]?.string ?? Brain.defaultId
        t4Loaded = j["t4_loaded"]?.string
    }

    init(brains: [Brain]) {
        self.brains = brains
        defaultId = Brain.defaultId
        t4Loaded = nil
    }

    static let fallback = BrainCatalog(brains: Brain.fallback)

    func brain(_ id: String?) -> Brain? {
        brains.first { $0.id == (id ?? defaultId) }
    }
}
