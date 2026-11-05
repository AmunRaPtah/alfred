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
    private static let useServerVoiceKey = "alfred.voice.useServerVoice"
    private static let serverEngineKey = "alfred.voice.serverEngine"
    private static let serverVoiceKey = "alfred.voice.serverVoice"

    var voiceIdentifier: String? {
        didSet { UserDefaults.standard.set(voiceIdentifier, forKey: Self.voiceKey) }
    }
    var rate: Float {
        didSet { UserDefaults.standard.set(rate, forKey: Self.rateKey) }
    }
    var autoListen: Bool {
        didSet { UserDefaults.standard.set(autoListen, forKey: Self.autoListenKey) }
    }

    /// Speak replies with the server's TTS (/tts) rather than the on-device
    /// synthesizer. Off means AVSpeechSynthesizer only.
    var useServerVoice: Bool {
        didSet { UserDefaults.standard.set(useServerVoice, forKey: Self.useServerVoiceKey) }
    }
    /// Server TTS engine/voice; nil means "whatever the server defaults to".
    var serverEngine: String? {
        didSet { UserDefaults.standard.set(serverEngine, forKey: Self.serverEngineKey) }
    }
    var serverVoice: String? {
        didSet { UserDefaults.standard.set(serverVoice, forKey: Self.serverVoiceKey) }
    }

    init() {
        voiceIdentifier = UserDefaults.standard.string(forKey: Self.voiceKey) ?? Self.defaultVoiceIdentifier()
        if let saved = UserDefaults.standard.object(forKey: Self.rateKey) as? Float {
            rate = saved
        } else {
            rate = AVSpeechUtteranceDefaultSpeechRate
        }
        autoListen = (UserDefaults.standard.object(forKey: Self.autoListenKey) as? Bool) ?? true
        useServerVoice = (UserDefaults.standard.object(forKey: Self.useServerVoiceKey) as? Bool) ?? true
        serverEngine = UserDefaults.standard.string(forKey: Self.serverEngineKey)
        serverVoice = UserDefaults.standard.string(forKey: Self.serverVoiceKey)
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
