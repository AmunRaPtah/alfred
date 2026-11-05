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
    /// Weekly Kaggle quota in hours per tier ("gpu"/"tpu"), from kaggle-quota.
    var quota: [String: Quota] = [:]
    var quotaRefresh: String?

    struct Quota: Hashable {
        var used: Double
        var allowed: Double
        var left: Double
    }

    init(json j: JSONValue) {
        brains = (j["brains"]?.array ?? j.array ?? []).compactMap(Brain.init(json:))
        defaultId = j["default"]?.string ?? Brain.defaultId
        t4Loaded = j["t4_loaded"]?.string
        if let q = j["quota"] {
            quotaRefresh = q["refresh"]?.string
            for tier in ["gpu", "tpu"] {
                if let t = q[tier], let used = t["used_h"]?.double, let allowed = t["allowed_h"]?.double {
                    quota[tier] = Quota(used: used, allowed: allowed, left: t["left_h"]?.double ?? allowed - used)
                }
            }
        }
    }

    init(brains: [Brain]) {
        self.brains = brains
        defaultId = Brain.defaultId
        t4Loaded = nil
    }

    /// "Quota: 4.2 of 6 h used this week, 1.8 h left. Resets Sat 7 Nov."
    func quotaLine(_ tier: String) -> String? {
        guard let q = quota[tier] else { return nil }
        let f = { (x: Double) in String(format: x == x.rounded() ? "%.0f" : "%.1f", x) }
        var line = q.left <= 0
            ? "Quota used up: \(f(q.used)) of \(f(q.allowed)) h this week."
            : "Quota: \(f(q.used)) of \(f(q.allowed)) h used this week, \(f(q.left)) h left."
        if let r = quotaRefresh, let d = ISO8601DateFormatter.withFractional.date(from: r) {
            line += " Resets " + d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + "."
        }
        return line
    }

    static let fallback = BrainCatalog(brains: Brain.fallback)

    func brain(_ id: String?) -> Brain? {
        brains.first { $0.id == (id ?? defaultId) }
    }
}

private extension ISO8601DateFormatter {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
