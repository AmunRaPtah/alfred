import SwiftUI

/// The scrolling conversation body for Ask Alfred. Structurally similar to
/// Helm's ChatView (autoscroll, jump-to-bottom, resume/error banners) but
/// built from Alfred's own components and styling throughout.
struct ThreadView: View {
    @Bindable var model: ChatModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var atBottom = true
    @State private var showVoice = false

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { outer in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.transcript.isEmpty && model.pending.isEmpty {
                            ButlerEmptyState(text: "Alfred is listening. Say what you need.")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 60)
                        }
                        ForEach(model.transcript.items) { item in
                            ThreadItemView(item: item, isLive: model.isRunning)
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
                            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 34, height: 34)
                                .foregroundStyle(AlfredPalette.parchment)
                                .background(AlfredPalette.slate.opacity(0.9), in: Circle())
                                .overlay(Circle().strokeBorder(AlfredPalette.brass.opacity(0.3)))
                        }
                        .padding(.bottom, 10)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: atBottom)
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
            model.start()
            Task { await model.refreshSession() }
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
                .font(AlfredFont.ui(14))
                .foregroundStyle(AlfredPalette.parchment)
            Spacer()
            Button(action: action) {
                if isResuming { ProgressView().tint(AlfredPalette.midnight) } else { Text("Wake Alfred").fontWeight(.semibold) }
            }
            .buttonStyle(.borderedProminent)
            .tint(AlfredPalette.brass)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(isResuming)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AlfredPalette.midnight.opacity(0.95))
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
        .padding(.vertical, 8)
        .background(AlfredPalette.caution.opacity(0.15))
    }
}
