import AVFoundation
import Observation
import Speech

/// Drives Alfred's live voice mode: SFSpeechRecognizer + AVAudioEngine for
/// listening, then one of two reply paths:
/// - server turn (preferred): POST /voice/turn streams sentences over SSE;
///   each is spoken with server TTS (/tts, AVAudioPlayer, next sentence
///   prefetched while the current one plays), falling back per sentence to
///   AVSpeechSynthesizer when /tts fails or takes longer than 20 s (Kokoro on
///   the Kaggle CPU runs ~1-2x slower than real time, so a short budget made
///   most sentences fall back to the robotic on-device voice).
/// - transcript (fallback, when /voice/turn fails): VoiceModeView sends over
///   ChatModel/SessionStream and feeds the streamed reply to `speakDelta`.
/// Barge-in and think-tag stripping live here so the view stays a thin
/// status display.
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
    /// Set when the server reports an `action` (a harness task was queued).
    private(set) var queuedTask: String?
    /// False while a /voice/turn reply is being spoken; VoiceModeView must
    /// then not also speak the session transcript.
    private(set) var transcriptDrivesSpeech = true

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

    // Server-turn state (/voice/turn + /tts).
    private struct Segment {
        var text: String
        var audio: Task<Data?, Never>?
    }
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var turnGeneration = 0
    @ObservationIgnored private var serverAPI: APIClient?
    @ObservationIgnored private var segments: [Segment] = []
    @ObservationIgnored private var segmentPlaying = false
    @ObservationIgnored private var synthSegmentActive = false
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playerDelegate: PlayerDelegate?

    private static let ttsTimeoutNanos: UInt64 = 20_000_000_000

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
        if playerDelegate == nil { playerDelegate = PlayerDelegate(engine: self) }
        do {
            try activateSession()
        } catch {
            phase = .error("Couldn't start audio: \(error.localizedDescription)")
            return
        }
        beginListening()
    }

    func stop() {
        cancelServerTurn()
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
        let wasServerTurn = turnTask != nil
        cancelServerTurn()
        synthesizer.stopSpeaking(at: .immediate)
        pendingUtterances = 0
        resetSpeechBuffer()
        finalReceived = false
        if phase == .speaking || (wasServerTurn && phase == .thinking) { beginListening() }
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
            player?.pause()
            if audioEngine.isRunning { audioEngine.pause() }
        case .ended:
            let shouldResume = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            guard shouldResume, phase != .idle else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            try? audioEngine.start()
            synthesizer.continueSpeaking()
            player?.play()
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
            pendingUtterances += 1
            synthesizer.speak(makeUtterance(text))
        }
    }

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = settings.rate
        if let id = settings.voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        }
        return utterance
    }

    fileprivate func utteranceDone() {
        pendingUtterances = max(0, pendingUtterances - 1)
        if synthSegmentActive {
            synthSegmentActive = false
            segmentFinished()
            return
        }
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

    // MARK: Server turn (/voice/turn + /tts)

    /// Runs the finalized utterance through POST /voice/turn and speaks each
    /// streamed sentence in order. If the endpoint fails before sending
    /// anything, switches back to transcript-driven speech and calls
    /// `fallback` (the plain session-message path).
    func runServerTurn(_ text: String, api: APIClient, sessionId: String,
                       fallback: @escaping @MainActor () async -> Void) {
        cancelServerTurn()
        turnGeneration += 1
        let gen = turnGeneration
        serverAPI = api
        queuedTask = nil
        finalReceived = false
        transcriptDrivesSpeech = false
        let voice = settings.useServerVoice ? settings.serverVoice : nil
        turnTask = Task { [weak self] in
            var gotAnything = false
            var failed = false
            do {
                for try await event in api.voiceTurn(sessionId: sessionId, text: text, voice: voice) {
                    guard let self, gen == self.turnGeneration else { return }
                    switch event.name {
                    case "sentence":
                        gotAnything = true
                        if let s = event.data["text"]?.string { self.enqueueSegment(s) }
                    case "action":
                        gotAnything = true
                        self.queuedTask = event.data["task"]?.string ?? "Task"
                    case "done":
                        gotAnything = true
                    case "error":
                        if !gotAnything { failed = true }
                    default:
                        break
                    }
                    if event.name == "done" || event.name == "error" { break }
                }
            } catch {
                if error is CancellationError { return }
                if !gotAnything { failed = true }
            }
            guard let self, gen == self.turnGeneration else { return }
            self.turnTask = nil
            if failed {
                self.transcriptDrivesSpeech = true
                await fallback()
            } else {
                self.finalReceived = true
                self.maybeFinishServerTurn()
            }
        }
    }

    private func cancelServerTurn() {
        turnGeneration += 1
        turnTask?.cancel(); turnTask = nil
        for seg in segments { seg.audio?.cancel() }
        segments = []
        player?.stop(); player = nil
        segmentPlaying = false
        synthSegmentActive = false
    }

    private func enqueueSegment(_ raw: String) {
        guard let text = Self.sanitize(raw) else { return }
        if phase == .thinking { phase = .speaking }
        segments.append(Segment(text: text, audio: nil))
        if segmentPlaying { prefetchNext() } else { playNextSegment() }
    }

    /// Starts fetching audio for every queued sentence, so the TTS server is
    /// never idle while the current one plays.
    private func prefetchNext() {
        guard settings.useServerVoice else { return }
        for i in segments.indices where segments[i].audio == nil {
            segments[i].audio = fetchAudio(segments[i].text)
        }
    }

    /// Resolves to the mp3 bytes, or nil if /tts failed or missed the 20 s budget.
    private func fetchAudio(_ text: String) -> Task<Data?, Never>? {
        guard let api = serverAPI else { return nil }
        let engine = settings.serverEngine
        let voice = settings.serverVoice
        let timeout = Self.ttsTimeoutNanos
        return Task {
            await withTaskGroup(of: Data?.self) { group in
                group.addTask { try? await api.tts(text: text, voice: voice, engine: engine) }
                group.addTask {
                    try? await Task.sleep(nanoseconds: timeout)
                    return nil
                }
                var result: Data?
                if let first = await group.next() { result = first }
                group.cancelAll()
                return result
            }
        }
    }

    private func playNextSegment() {
        guard !segmentPlaying else { return }
        guard !segments.isEmpty else { maybeFinishServerTurn(); return }
        var seg = segments.removeFirst()
        segmentPlaying = true
        if seg.audio == nil, settings.useServerVoice { seg.audio = fetchAudio(seg.text) }
        prefetchNext()
        let gen = turnGeneration
        let text = seg.text
        let audio = seg.audio
        Task { [weak self] in
            let data = await audio?.value
            guard let self, gen == self.turnGeneration else { return }
            self.playSegment(text, data: data)
        }
    }

    private func playSegment(_ text: String, data: Data?) {
        if let data, let p = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue) {
            p.delegate = playerDelegate
            player = p
            if p.play() { return }
            player = nil
        }
        // Server TTS unavailable or too slow for this sentence: on-device voice.
        synthSegmentActive = true
        pendingUtterances += 1
        synthesizer.speak(makeUtterance(text))
    }

    fileprivate func playerFinished(_ p: AVAudioPlayer) {
        guard p === player else { return }
        segmentFinished()
    }

    private func segmentFinished() {
        player = nil
        segmentPlaying = false
        playNextSegment()
    }

    private func maybeFinishServerTurn() {
        guard !transcriptDrivesSpeech, finalReceived, segments.isEmpty, !segmentPlaying else { return }
        guard phase == .speaking || phase == .thinking else { return }
        if settings.autoListen {
            beginListening()
        } else {
            phase = .idle
        }
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

/// AVAudioPlayerDelegate for server-TTS sentences; forwards completion (or a
/// decode error, treated the same) back onto the engine on the main actor.
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    weak var engine: VoiceEngine?
    init(engine: VoiceEngine) { self.engine = engine }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak engine] in engine?.playerFinished(player) }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak engine] in engine?.playerFinished(player) }
    }
}
