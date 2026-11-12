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
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(AlfredPalette.mist)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(AlfredPalette.hairline, lineWidth: 0.75))
                }
                .accessibilityLabel("Close voice mode")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            BrassOrb(mode: orbMode)
                .frame(width: 220, height: 220)
                .accessibilityHidden(true)
            statusLabel

            Text(transcriptText)
                .font(AlfredFont.voice(21))
                .foregroundStyle(AlfredPalette.parchment)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 32)
                .frame(minHeight: 72)
                .animation(AlfredMotion.quick, value: transcriptText)

            if voice.queuedTask != nil {
                Label("Task queued", systemImage: "checklist")
                    .font(AlfredFont.ui(13, weight: .medium))
                    .foregroundStyle(AlfredPalette.brass)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(AlfredPalette.surface.opacity(0.85), in: Capsule())
                    .overlay(Capsule().strokeBorder(AlfredPalette.hairline, lineWidth: 0.75))
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
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
        .onChange(of: voice.phase) { _, phase in
            if phase == .listening || phase == .speaking { Haptics.tap() }
        }
        .animation(AlfredMotion.spring, value: voice.queuedTask != nil)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Status

    private var orbMode: BrassOrb.Mode {
        switch voice.phase {
        case .idle: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .permissionNeeded, .error: return .trouble
        }
    }

    private var statusLabel: some View {
        Text(label)
            .font(AlfredFont.label)
            .foregroundStyle(orbMode == .trouble ? AlfredPalette.caution : AlfredPalette.brass)
            .textCase(.uppercase)
            .tracking(2)
            .contentTransition(.opacity)
            .animation(AlfredMotion.fade, value: label)
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
            Button { voice.stop(); dismiss() } label: { QuietCapsule(title: "Close", tint: AlfredPalette.parchment) }
                .buttonStyle(PressableStyle())
        case .idle:
            Button {
                Haptics.tap()
                Task { await voice.start() }
            } label: { BrassCapsule(title: "Start listening", systemImage: "mic") }
                .buttonStyle(PressableStyle())
        }
    }

    private func circleButton(systemImage: String, tint: Color, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: big ? 21 : 16, weight: .bold))
                .frame(width: big ? 66 : 50, height: big ? 66 : 50)
                .foregroundStyle(tint)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(tint.opacity(0.55), lineWidth: 1))
                .shadow(color: tint.opacity(0.25), radius: 12, x: 0, y: 3)
        }
        .buttonStyle(PressableStyle())
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

/// The heart of voice mode: a brass sphere that breathes with Alfred's state.
/// Listening ripples outward, thinking turns slowly with a passing sheen,
/// speaking swells more fully, idle rests dim. Trouble turns terracotta.
/// Driven by TimelineView so nothing loops forever when reduce motion is on.
struct BrassOrb: View {
    enum Mode: Equatable { case idle, listening, thinking, speaking, trouble }

    let mode: Mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || mode == .idle)) { context in
            orb(at: context.date.timeIntervalSinceReferenceDate)
        }
        .animation(AlfredMotion.fade, value: mode)
    }

    private var speed: Double {
        switch mode {
        case .idle: return 0.4
        case .listening: return 2.2
        case .thinking: return 0.9
        case .speaking: return 3.4
        case .trouble: return 0.6
        }
    }

    private var amplitude: Double {
        switch mode {
        case .idle: return 0.0
        case .listening: return 0.035
        case .thinking: return 0.02
        case .speaking: return 0.07
        case .trouble: return 0.015
        }
    }

    private var light: Color { mode == .trouble ? Color(hex: 0xE3A68A) : AlfredPalette.brassLight }
    private var mid: Color { mode == .trouble ? AlfredPalette.caution : AlfredPalette.brass }
    private var deep: Color { mode == .trouble ? Color(hex: 0x7A3F2C) : AlfredPalette.brassDeep }

    private func orb(at t: Double) -> some View {
        let phase = reduceMotion ? 0 : t * speed
        let breath = 1.0 + amplitude * sin(phase)
        let glow = mode == .idle ? 0.18 : 0.32 + 0.12 * sin(phase)
        let ripple = reduceMotion ? 0.5 : (t * 0.55).truncatingRemainder(dividingBy: 1)
        let sheen = reduceMotion ? 0 : (t * 0.35).truncatingRemainder(dividingBy: 1)
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: [mid.opacity(glow), .clear], center: .center, startRadius: 30, endRadius: 110))
                .scaleEffect(breath * 1.05)
            if mode == .listening {
                Circle()
                    .strokeBorder(mid.opacity(0.45 * (1 - ripple)), lineWidth: 1)
                    .scaleEffect(0.6 + 0.4 * ripple)
                Circle()
                    .strokeBorder(mid.opacity(0.3 * (1 - (ripple + 0.5).truncatingRemainder(dividingBy: 1))), lineWidth: 1)
                    .scaleEffect(0.6 + 0.4 * (ripple + 0.5).truncatingRemainder(dividingBy: 1))
            }
            Circle()
                .fill(RadialGradient(colors: [light, mid, deep], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 4, endRadius: 80))
                .frame(width: 120, height: 120)
                .overlay {
                    if mode == .thinking {
                        Circle()
                            .fill(LinearGradient(colors: [.clear, Color.white.opacity(0.28), .clear],
                                                 startPoint: UnitPoint(x: sheen * 2 - 0.6, y: 0),
                                                 endPoint: UnitPoint(x: sheen * 2 - 0.1, y: 1)))
                            .blendMode(.overlay)
                    }
                }
                .overlay(Circle().strokeBorder(light.opacity(0.4), lineWidth: 0.75))
                .shadow(color: mid.opacity(0.45), radius: 24, x: 0, y: 6)
                .scaleEffect(breath)
                .opacity(mode == .idle ? 0.55 : 1)
        }
    }
}
