import SwiftUI

/// The scrolling conversation body for Ask Alfred. Structurally similar to
/// Helm's ChatView (autoscroll, jump-to-bottom, resume/error banners) but
/// built from Alfred's own components and styling throughout.
struct ThreadView: View {
    @Bindable var model: ChatModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var atBottom = true
    @State private var showVoice = false
    /// Transcript items at or past this index arrived while the thread was
    /// open and get a soft entrance; earlier ones (history) appear still.
    @State private var revealFrom = Int.max
    @State private var openedAt = Date()

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { outer in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.transcript.isEmpty && model.pending.isEmpty {
                            ButlerEmptyState(text: "At your service.",
                                             detail: "Tell me what you need, and I shall see to it.")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 80)
                        }
                        let items = model.transcript.items
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ThreadItemView(item: item, isLive: model.isRunning,
                                           reveal: index >= revealFrom && index >= items.count - 3)
                                .id(item.id)
                        }
                        ForEach(model.pending) { p in
                            PendingTurn(message: p,
                                        onRetry: { Task { await model.retry(p) } },
                                        onDiscard: { model.discard(p) },
                                        onCancel: { Task { await model.cancelQueued(p) } })
                        }
                        if model.isRunning {
                            ThinkingTypingIndicator()
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .background(BottomTracker())
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .coordinateSpace(name: "threadScroll")
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onPreferenceChange(BottomOffsetKey.self) { maxY in
                    atBottom = maxY <= outer.size.height + 120
                }
                .onChange(of: scrollKey) {
                    guard atBottom else { return }
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear {
                    Task {
                        try? await Task.sleep(nanoseconds: 60_000_000)
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottom) {
                    if !atBottom {
                        Button {
                            Haptics.tap()
                            withAnimation(AlfredMotion.spring) { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 36, height: 36)
                                .foregroundStyle(AlfredPalette.brass)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(AlfredPalette.hairline, lineWidth: 0.75))
                                .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
                        }
                        .accessibilityLabel("Jump to latest")
                        .padding(.bottom, 10)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(AlfredMotion.fade, value: atBottom)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if model.isExited {
                    ResumeStrip(isResuming: model.isResuming) { Task { await model.resume() } }
                }
                if let banner = model.banner {
                    TroubleStrip(text: banner) { model.banner = nil }
                }
                AlfredComposer(model: model, onVoice: { showVoice = true })
            }
        }
        .fullScreenCover(isPresented: $showVoice) {
            VoiceModeView(model: model)
        }
        .sensoryFeedback(.success, trigger: model.turnCompletions)
        .onAppear {
            openedAt = Date()
            revealFrom = model.transcript.items.count
            model.start()
            Task { await model.refreshSession() }
        }
        // History that streams in right after opening stays still; anything
        // arriving later reveals itself.
        .onChange(of: model.transcript.items.count) { _, count in
            if Date().timeIntervalSince(openedAt) < 1.5 { revealFrom = count }
        }
        .onChange(of: model.session.id) { _, _ in
            openedAt = Date()
            revealFrom = model.transcript.items.count
        }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.start() } else if phase == .background { model.stop() }
        }
    }

    private var scrollKey: String {
        let last = model.transcript.items.last
        let len = last.map { $0.copyText.count } ?? 0
        return "\(model.transcript.items.count)-\(len)-\(model.pending.count)-\(model.isRunning)"
    }
}

private struct BottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct BottomTracker: View {
    var body: some View {
        GeometryReader { g in
            Color.clear.preference(key: BottomOffsetKey.self, value: g.frame(in: .named("threadScroll")).maxY)
        }
    }
}

struct ResumeStrip: View {
    let isResuming: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.stars").foregroundStyle(AlfredPalette.mist)
            Text("This conversation has ended.")
                .font(AlfredFont.voice(15))
                .italic()
                .foregroundStyle(AlfredPalette.parchment)
            Spacer()
            Button {
                Haptics.tap()
                action()
            } label: {
                if isResuming {
                    BrassDots(size: 5)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                } else {
                    BrassCapsule(title: "Wake Alfred")
                }
            }
            .buttonStyle(PressableStyle())
            .disabled(isResuming)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AlfredPalette.night.opacity(0.92))
        .overlay(alignment: .top) {
            Rectangle().fill(AlfredPalette.brass.opacity(0.15)).frame(height: 0.5)
        }
    }
}

struct TroubleStrip: View {
    let text: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AlfredPalette.caution)
            Text(text).font(AlfredFont.caption).foregroundStyle(AlfredPalette.parchment)
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(AlfredPalette.mist)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(AlfredPalette.caution.opacity(0.16))
        .background(AlfredPalette.night)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
