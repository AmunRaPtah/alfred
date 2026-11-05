import SwiftUI

/// Full-screen live voice conversation with Alfred: listens, shows a live
/// transcript, sends the utterance through POST /voice/turn (or, if that
/// fails, over the existing session stream), and speaks the reply back as it
/// streams in. All orchestration lives in VoiceEngine; this view is just
/// status + controls.
struct VoiceModeView: View {
    @Bindable var model: ChatModel
    @Environment(\.dismiss) private var dismiss

    @State private var voice = VoiceEngine(settings: VoiceSettings.shared)
    @State private var lastAssistantId: String?
    @State private var lastAssistantLength = 0
    @State private var finishedIds: Set<String> = []

    var body: some View {
        VStack(spacing: 28) {
            HStack {
                Spacer()
                Button {
                    voice.stop()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(AlfredPalette.mist)
                        .background(AlfredPalette.slate.opacity(0.7), in: Circle())
                }
                .accessibilityLabel("Close voice mode")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            statusGlyph
            statusLabel

            Text(transcriptText)
                .font(AlfredFont.voice(18))
                .foregroundStyle(AlfredPalette.parchment)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .frame(minHeight: 60)
                .animation(.easeOut(duration: 0.15), value: transcriptText)

            if voice.queuedTask != nil {
                Label("Task queued", systemImage: "checklist")
                    .font(AlfredFont.ui(13, weight: .medium))
                    .foregroundStyle(AlfredPalette.brass)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(AlfredPalette.slate.opacity(0.7), in: Capsule())
                    .accessibilityLabel("Task queued: \(voice.queuedTask ?? "")")
            }

            Spacer()

            controls
                .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AlfredBackground())
        .onAppear {
            voice.onUtterance = { text in
                voice.runServerTurn(text, api: model.api, sessionId: model.session.id) {
                    await model.sendVoice(text)
                }
            }
            Task { await voice.start() }
        }
        .onDisappear { voice.stop() }
        .onChange(of: activityKey) { _, _ in handleItems(model.transcript.items) }
    }

    // MARK: Status

    @ViewBuilder
    private var statusGlyph: some View {
        Image(systemName: glyphName)
            .font(.system(size: 54, weight: .light))
            .foregroundStyle(glyphColor)
            .symbolEffect(.pulse, isActive: voice.phase == .listening || voice.phase == .speaking)
    }

    private var glyphName: String {
        switch voice.phase {
        case .idle: return "moon.stars"
        case .listening: return "waveform"
        case .thinking: return "hourglass"
        case .speaking: return "speaker.wave.2.fill"
        case .permissionNeeded: return "mic.slash"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var glyphColor: Color {
        switch voice.phase {
        case .listening: return AlfredPalette.signal
        case .thinking: return AlfredPalette.brass
        case .speaking: return AlfredPalette.brass
        case .permissionNeeded, .error: return AlfredPalette.caution
        case .idle: return AlfredPalette.mist
        }
    }

    private var statusLabel: some View {
        Text(label)
            .font(AlfredFont.ui(14, weight: .medium))
            .foregroundStyle(AlfredPalette.mist)
            .textCase(.uppercase)
            .tracking(1.2)
    }

    private var label: String {
        switch voice.phase {
        case .idle: return "Ended"
        case .listening: return "Listening"
        case .thinking: return "Thinking\u{2026} this can take a minute"
        case .speaking: return "Speaking"
        case .permissionNeeded: return "Permission needed"
        case .error: return "Trouble"
        }
    }

    private var transcriptText: String {
        switch voice.phase {
        case .listening: return voice.liveTranscript.isEmpty ? "Say something\u{2026}" : voice.liveTranscript
        case .permissionNeeded(let msg): return msg
        case .error(let msg): return msg
        default: return ""
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        switch voice.phase {
        case .listening:
            HStack(spacing: 24) {
                circleButton(systemImage: "arrow.up", tint: AlfredPalette.brass) { voice.tapToSend() }
                    .accessibilityLabel("Send now")
                circleButton(systemImage: "xmark", tint: AlfredPalette.caution, big: true) {
                    voice.stop(); dismiss()
                }
                .accessibilityLabel("End voice mode")
            }
        case .speaking, .thinking:
            circleButton(systemImage: "stop.fill", tint: AlfredPalette.caution, big: true) {
                voice.interrupt()
                Task { await model.interrupt() }
            }
            .accessibilityLabel("Stop")
        case .permissionNeeded, .error:
            Button("Close") { voice.stop(); dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(AlfredPalette.brass)
        case .idle:
            Button("Start listening") { Task { await voice.start() } }
                .buttonStyle(.borderedProminent)
                .tint(AlfredPalette.brass)
        }
    }

    private func circleButton(systemImage: String, tint: Color, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: big ? 22 : 16, weight: .bold))
                .frame(width: big ? 64 : 48, height: big ? 64 : 48)
                .foregroundStyle(AlfredPalette.midnight)
                .background(tint, in: Circle())
        }
    }

    // MARK: Streaming the reply into speech

    /// A cheap key that changes whenever the last transcript item grows or a
    /// new one appears, without comparing the whole array each time.
    private var activityKey: String {
        guard let last = model.transcript.items.last else { return "0" }
        return "\(last.id)-\(last.copyText.count)"
    }

    private func handleItems(_ items: [ChatItem]) {
        guard let last = items.last, case .assistant(let text, let isFinal) = last.kind else { return }
        if last.id != lastAssistantId {
            lastAssistantId = last.id
            lastAssistantLength = 0
        }
        // While a /voice/turn reply is being spoken, the same reply may also
        // land in the transcript; keep the bookkeeping but don't speak it twice.
        let speak = voice.transcriptDrivesSpeech
        if text.count > lastAssistantLength {
            let delta = String(text.dropFirst(lastAssistantLength))
            lastAssistantLength = text.count
            if speak { voice.speakDelta(delta) }
        }
        if isFinal, !finishedIds.contains(last.id) {
            finishedIds.insert(last.id)
            if speak { voice.finishReply() }
        }
    }
}
