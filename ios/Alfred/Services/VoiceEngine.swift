import AVFoundation
import Observation
import Speech

/// Drives Alfred's live voice mode: SFSpeechRecognizer + AVAudioEngine for
/// listening, AVSpeechSynthesizer for speaking the streamed reply back.
/// Entirely on-device plumbing; the session/text transport is unchanged
/// (VoiceModeView still sends over ChatModel/SessionStream). Barge-in and
/// think-tag stripping live here so the view stays a thin status display.
@Observable
@MainActor
final class VoiceEngine {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking
        case permissionNeeded(String)
        case error(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var liveTranscript = ""
    private(set) var isOnDevice = false

    var settings: VoiceSettings
    /// Fired with a finalized user utterance, ready to send.
    var onUtterance: ((String) -> Void)?

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var silenceTimer: Task<Void, Never>?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var synthDelegate: SynthDelegate?
    @ObservationIgnored private var pendingUtterances = 0
    @ObservationIgnored private var finalReceived = false
    @ObservationIgnored private var tapInstalled = false
    @ObservationIgnored private var sessionActive = false
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    // Speech-buffer state for the current assistant reply.
    @ObservationIgnored private var rawAccumulated = ""
    @ObservationIgnored private var lastCutOffset: Int?
    @ObservationIgnored private var visibleConsumedCount = 0
    @ObservationIgnored private var pendingSpeech = ""
    @ObservationIgnored private var codeFenceOpen = false

    private static let bargeInThreshold: Float = 0.035

    init(settings: VoiceSettings) {
        self.settings = settings
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer()
    }

    // MARK: Lifecycle

    func start() async {
        guard phase == .idle else { return }
        guard await requestSpeechAuthorization() else {
            phase = .permissionNeeded("Alfred needs Speech Recognition access to hear you. Enable it in Settings.")
            return
        }
        guard await requestMicAuthorization() else {
            phase = .permissionNeeded("Alfred needs Microphone access to hear you. Enable it in Settings.")
            return
        }
        if synthDelegate == nil {
            let d = SynthDelegate(engine: self)
            synthDelegate = d
            synthesizer.delegate = d
        }
        do {
            try activateSession()
        } catch {
            phase = .error("Couldn't start audio: \(error.localizedDescription)")
            return
        }
        beginListening()
    }

    func stop() {
        silenceTimer?.cancel(); silenceTimer = nil
        recognitionTask?.cancel(); recognitionTask = nil
        request?.endAudio(); request = nil
        if tapInstalled { audioEngine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        if audioEngine.isRunning { audioEngine.stop() }
        synthesizer.stopSpeaking(at: .immediate)
        pendingUtterances = 0
        deactivateSession()
        phase = .idle
        liveTranscript = ""
    }

    /// Force-finalize whatever the user has said so far (the tap-to-send button).
    func tapToSend() { finalizeUtterance() }

    /// Barge-in / stop button: cut Alfred off and go back to listening.
    func interrupt() {
        synthesizer.stopSpeaking(at: .immediate)
        pendingUtterances = 0
        resetSpeechBuffer()
        finalReceived = false
        if phase == .speaking { beginListening() }
    }

    // MARK: Permissions

    private func requestSpeechAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicAuthorization() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    // MARK: Audio session

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        sessionActive = true
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
    }

    private func deactivateSession() {
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o); interruptionObserver = nil }
        guard sessionActive else { return }
        sessionActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            synthesizer.pauseSpeaking(at: .immediate)
            if audioEngine.isRunning { audioEngine.pause() }
        case .ended:
            let shouldResume = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            guard shouldResume, phase != .idle else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            try? audioEngine.start()
            synthesizer.continueSpeaking()
        @unknown default:
            break
        }
    }

    // MARK: Listening

    private func beginListening() {
        phase = .listening
        liveTranscript = ""
        recognitionTask?.cancel()
        recognitionTask = nil

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if let recognizer, recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
            isOnDevice = true
        } else {
            isOnDevice = false
        }
        request = req

        if !tapInstalled {
            let node = audioEngine.inputNode
            let format = node.outputFormat(forBus: 0)
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                let rms = VoiceEngine.rms(of: buffer)
                Task { @MainActor in self?.consume(buffer, rms: rms) }
            }
            tapInstalled = true
        }
        if !audioEngine.isRunning {
            audioEngine.prepare()
            try? audioEngine.start()
        }

        guard let recognizer, recognizer.isAvailable else {
            phase = .error("Speech recognition isn't available right now.")
            return
        }
        recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in self?.handleRecognition(result: result, error: error) }
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer, rms: Float) {
        request?.append(buffer)
        if phase == .speaking, rms > Self.bargeInThreshold { interrupt() }
    }

    private nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += channel[i] * channel[i] }
        return (sum / Float(n)).squareRoot()
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        guard let result else { return }
        liveTranscript = result.bestTranscription.formattedString
        resetSilenceTimer()
        if result.isFinal { finalizeUtterance() }
    }

    private func resetSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.finalizeUtterance()
        }
    }

    private func finalizeUtterance() {
        guard phase == .listening else { return }
        silenceTimer?.cancel(); silenceTimer = nil
        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        recognitionTask?.cancel(); recognitionTask = nil
        request?.endAudio(); request = nil
        liveTranscript = ""
        guard !text.isEmpty else { beginListening(); return }
        phase = .thinking
        resetSpeechBuffer()
        finalReceived = false
        onUtterance?(text)
    }

    // MARK: Speaking the streamed reply

    /// Feed another chunk of the assistant's reply as it streams in. Strips
    /// leaked `<think>...</think>` reasoning and speaks complete sentences
    /// once they arrive; code fences are replaced with "Code omitted."
    func speakDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        enqueueSpeech(extractSpeakable(delta))
    }

    /// Call once the server's final `assistant` event lands: flushes any
    /// trailing partial sentence and arranges to resume listening once
    /// speech finishes.
    func finishReply() {
        finalReceived = true
        let tail = pendingSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty, !codeFenceOpen, let s = Self.sanitize(pendingSpeech) {
            enqueueSpeech([s])
        }
        pendingSpeech = ""
        maybeResumeListening()
    }

    private func extractSpeakable(_ delta: String) -> [String] {
        rawAccumulated += delta
        var visible = rawAccumulated
        if let r = rawAccumulated.range(of: "</think>", options: .backwards) {
            let offset = rawAccumulated.distance(from: rawAccumulated.startIndex, to: r.upperBound)
            visible = String(rawAccumulated[r.upperBound...])
            if lastCutOffset != offset {
                lastCutOffset = offset
                visibleConsumedCount = 0
                pendingSpeech = ""
                codeFenceOpen = false
            }
        }
        guard visible.count > visibleConsumedCount else { return [] }
        let newPart = String(visible.dropFirst(visibleConsumedCount))
        visibleConsumedCount = visible.count
        pendingSpeech += newPart
        let (utterances, leftover) = Self.splitAndSpeak(pendingSpeech, codeFenceOpen: &codeFenceOpen)
        pendingSpeech = leftover
        return utterances.compactMap(Self.sanitize)
    }

    private func enqueueSpeech(_ utterances: [String]) {
        guard !utterances.isEmpty else { return }
        if phase == .thinking { phase = .speaking }
        for text in utterances {
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = settings.rate
            if let id = settings.voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id) {
                utterance.voice = voice
            }
            pendingUtterances += 1
            synthesizer.speak(utterance)
        }
    }

    fileprivate func utteranceDone() {
        pendingUtterances = max(0, pendingUtterances - 1)
        maybeResumeListening()
    }

    private func maybeResumeListening() {
        guard phase == .speaking, pendingUtterances == 0, finalReceived else { return }
        if settings.autoListen {
            beginListening()
        } else {
            phase = .idle
        }
    }

    private func resetSpeechBuffer() {
        rawAccumulated = ""
        lastCutOffset = nil
        visibleConsumedCount = 0
        pendingSpeech = ""
        codeFenceOpen = false
    }

    // MARK: Text processing

    /// Splits off whatever complete sentences it can from `text`, replacing
    /// fenced code blocks (which may span multiple calls) with a single
    /// "Code omitted." utterance. Returns the utterances found plus whatever
    /// incomplete tail should be carried over to the next call.
    private static func splitAndSpeak(_ text: String, codeFenceOpen: inout Bool) -> ([String], String) {
        var utterances: [String] = []
        var remaining = Substring(text)
        while true {
            if codeFenceOpen {
                guard let r = remaining.range(of: "```") else { return (utterances, String(remaining)) }
                remaining = remaining[r.upperBound...]
                codeFenceOpen = false
                utterances.append("Code omitted.")
            } else if let r = remaining.range(of: "```") {
                let before = String(remaining[remaining.startIndex..<r.lowerBound])
                let (complete, leftover) = extractComplete(before)
                utterances.append(contentsOf: complete)
                if !leftover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { utterances.append(leftover) }
                remaining = remaining[r.upperBound...]
                codeFenceOpen = true
            } else {
                let (complete, leftover) = extractComplete(String(remaining))
                utterances.append(contentsOf: complete)
                return (utterances, leftover)
            }
        }
    }

    private static func extractComplete(_ text: String) -> (complete: [String], leftover: String) {
        var complete: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { complete.append(trimmed) }
                current = ""
            }
        }
        return (complete, current)
    }

    /// Strips common markdown symbols from a sentence before it's spoken.
    private static func sanitize(_ s: String) -> String? {
        var t = s
        for sym in ["**", "__", "```", "`", "*", "_", "#", ">", "~~", "|"] {
            t = t.replacingOccurrences(of: sym, with: "")
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// AVSpeechSynthesizerDelegate must be an NSObject; this just forwards
/// finish/cancel back onto the engine on the main actor.
private final class SynthDelegate: NSObject, AVSpeechSynthesizerDelegate {
    weak var engine: VoiceEngine?
    init(engine: VoiceEngine) { self.engine = engine }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak engine] in engine?.utteranceDone() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak engine] in engine?.utteranceDone() }
    }
}
