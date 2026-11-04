import AVFoundation
import Observation

/// Persisted preferences for voice mode: which synthesizer voice to use, how
/// fast it speaks, and whether listening resumes automatically after Alfred
/// finishes speaking. Plain UserDefaults, same spirit as ServerConfig.
@Observable
final class VoiceSettings {
    static let shared = VoiceSettings()

    private static let voiceKey = "alfred.voice.voiceIdentifier"
    private static let rateKey = "alfred.voice.rate"
    private static let autoListenKey = "alfred.voice.autoListen"

    var voiceIdentifier: String? {
        didSet { UserDefaults.standard.set(voiceIdentifier, forKey: Self.voiceKey) }
    }
    var rate: Float {
        didSet { UserDefaults.standard.set(rate, forKey: Self.rateKey) }
    }
    var autoListen: Bool {
        didSet { UserDefaults.standard.set(autoListen, forKey: Self.autoListenKey) }
    }

    init() {
        voiceIdentifier = UserDefaults.standard.string(forKey: Self.voiceKey) ?? Self.defaultVoiceIdentifier()
        if let saved = UserDefaults.standard.object(forKey: Self.rateKey) as? Float {
            rate = saved
        } else {
            rate = AVSpeechUtteranceDefaultSpeechRate
        }
        autoListen = (UserDefaults.standard.object(forKey: Self.autoListenKey) as? Bool) ?? true
    }

    /// English voices, enhanced/premium quality sorted first.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { lhs, rhs in
                if lhs.quality.rawValue != rhs.quality.rawValue { return lhs.quality.rawValue > rhs.quality.rawValue }
                return lhs.name < rhs.name
            }
    }

    private static func defaultVoiceIdentifier() -> String? {
        availableVoices().first?.identifier
    }
}
