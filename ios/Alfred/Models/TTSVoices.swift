import Foundation

/// GET /tts/voices: the voices each server TTS engine offers, plus the
/// server's defaults.
struct TTSVoices: Equatable {
    var engines: [String: [String]]
    var defaultEngine: String?
    var defaultVoice: String?

    init(json j: JSONValue) {
        var engines: [String: [String]] = [:]
        if case .object(let o)? = j["engines"] {
            for (name, list) in o { engines[name] = list.stringArray }
        }
        self.engines = engines
        defaultEngine = j["default_engine"]?.string
        defaultVoice = j["default_voice"]?.string
    }

    /// Engine names, the server default first.
    var engineNames: [String] {
        engines.keys.sorted { lhs, rhs in
            if lhs == defaultEngine { return true }
            if rhs == defaultEngine { return false }
            return lhs < rhs
        }
    }
}
