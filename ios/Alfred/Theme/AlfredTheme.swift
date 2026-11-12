import SwiftUI
import UIKit

/// Alfred's palette and type system: "the butler's study". Deep midnight,
/// polished brass, parchment type. Warm and quiet, never an instrument panel.
/// Named hex tokens, used everywhere instead of system colors so the app reads
/// as its own thing rather than a reskin.
enum AlfredPalette {
    /// The deepest layer: the study at night.
    static let midnight = Color(hex: 0x0A0F1C)
    /// One step up: bars, strips, sheets.
    static let night = Color(hex: 0x111829)
    /// Raised surfaces: cards, rows, fields.
    static let surface = Color(hex: 0x18203A)
    /// Legacy name for `surface`, kept so existing call sites read the same.
    static let slate = surface
    /// The cloche's lamp-lit navy, used for the background glow.
    static let lamplight = Color(hex: 0x1F2A47)

    static let brassLight = Color(hex: 0xF3DDA6)
    static let brass = Color(hex: 0xD4AE68)
    static let brassDeep = Color(hex: 0x9C7638)

    static let parchment = Color(hex: 0xF1EAD9)
    static let mist = Color(hex: 0x8B94AA)
    /// Muted sage: things that are well.
    static let signal = Color(hex: 0x8FAE8E)
    /// Terracotta: things that need care.
    static let caution = Color(hex: 0xC47A5A)

    /// Polished brass, for hero moments only: the greeting rule, the send
    /// button, the voice orb.
    static var brassGradient: LinearGradient {
        LinearGradient(colors: [brassLight, brass, brassDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// A brass hairline that fades out at both ends.
    static var brassRule: LinearGradient {
        LinearGradient(colors: [brassLight, brass, brassDeep.opacity(0)], startPoint: .leading, endPoint: .trailing)
    }

    /// The low-opacity brass edge used on cards and fields.
    static var hairline: LinearGradient {
        LinearGradient(colors: [brassLight.opacity(0.30), brass.opacity(0.06)], startPoint: .top, endPoint: .bottom)
    }
}

enum AlfredFont {
    /// Alfred's own voice: a serif for anything he "says" (his replies,
    /// headings, the Today greeting).
    static func voice(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Functional UI text: composer, labels, buttons, lists.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static let greeting = voice(40, weight: .regular)
    static let title = voice(28, weight: .semibold)
    static let heading = voice(20, weight: .medium)
    static let body = ui(16)
    static let caption = ui(13)
    /// Tracked uppercase micro-label for section headers ("THIS MORNING").
    static let label = ui(11, weight: .semibold)
}

/// Slow, graceful motion. Nothing in Alfred's house hurries.
enum AlfredMotion {
    static let spring = Animation.spring(response: 0.5, dampingFraction: 0.9)
    static let fade = Animation.easeInOut(duration: 0.45)
    static let quick = Animation.easeInOut(duration: 0.25)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// The study at night: midnight, a warm lamp glow from above, a soft
/// vignette and a whisper of grain.
struct AlfredBackground: View {
    var body: some View {
        ZStack {
            AlfredPalette.midnight
            RadialGradient(colors: [AlfredPalette.lamplight, AlfredPalette.night.opacity(0.6), AlfredPalette.midnight.opacity(0)],
                           center: UnitPoint(x: 0.5, y: -0.08), startRadius: 0, endRadius: 560)
            RadialGradient(colors: [AlfredPalette.brass.opacity(0.09), AlfredPalette.brass.opacity(0)],
                           center: UnitPoint(x: 0.82, y: 0.02), startRadius: 0, endRadius: 360)
            RadialGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.42)],
                           center: .center, startRadius: 260, endRadius: 760)
            GrainOverlay()
                .opacity(0.05)
                .blendMode(.overlay)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A fixed, seeded speckle so the midnight never looks like flat plastic.
private struct GrainOverlay: View {
    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x5EED_A1F3
            func next() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double((seed >> 33) & 0xFFFF) / 65535.0
            }
            let count = 1800
            for _ in 0..<count {
                let x = next() * size.width
                let y = next() * size.height
                let light = next() > 0.5
                context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)),
                             with: .color(light ? Color.white : Color.black))
            }
        }
    }
}

/// Alfred's one recurring container: a softly raised surface with a brass
/// hairline and a gentle shadow, used for reminders, drafts and summaries.
struct ButlerCard<Content: View>: View {
    var padding: CGFloat
    var content: Content
    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [AlfredPalette.surface.opacity(0.94), AlfredPalette.night.opacity(0.94)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(AlfredPalette.hairline, lineWidth: 0.75)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Tracked uppercase micro-label for section headers.
struct SectionLabel: View {
    var text: String
    var color: Color = AlfredPalette.mist
    init(_ text: String, color: Color = AlfredPalette.mist) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(AlfredFont.label)
            .tracking(1.8)
            .foregroundStyle(color)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The brass service cloche from Alfred's icon, drawn as a shape so it can
/// sit at any size: dome, knob, plate and the small stand beneath.
struct ClocheShape: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height)
        }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: r.minX + x * r.width, y: r.minY + y * r.height, width: w * r.width, height: h * r.height)
        }
        var p = Path()
        // Knob and stem.
        p.addEllipse(in: rect(0.4494, 0.0, 0.1012, 0.1472))
        p.addRoundedRect(in: rect(0.482, 0.121, 0.036, 0.087),
                         cornerSize: CGSize(width: 0.012 * r.width, height: 0.012 * r.width))
        // Dome.
        p.move(to: pt(0.0833, 0.792))
        p.addCurve(to: pt(0.5, 0.1905), control1: pt(0.0833, 0.4026), control2: pt(0.2738, 0.1905))
        p.addCurve(to: pt(0.9167, 0.792), control1: pt(0.7262, 0.1905), control2: pt(0.9167, 0.4026))
        p.closeSubpath()
        // Plate.
        let plateH = 0.0736 * r.height
        p.addRoundedRect(in: rect(0, 0.831, 1, 0.0736), cornerSize: CGSize(width: plateH / 2, height: plateH / 2))
        // Stand.
        let standH = 0.0216 * r.height
        p.addRoundedRect(in: rect(0.268, 0.958, 0.452, 0.0216), cornerSize: CGSize(width: standH / 2, height: standH / 2))
        return p
    }
}

/// The cloche, filled with polished brass.
struct ClocheMark: View {
    var width: CGFloat = 44
    var body: some View {
        ClocheShape()
            .fill(AlfredPalette.brassGradient)
            .frame(width: width, height: width / 1.455)
            .accessibilityHidden(true)
    }
}

/// An empty state in Alfred's voice: the cloche under a soft glow, a line,
/// and optionally a quieter second line.
struct ButlerEmptyState: View {
    var text: String
    var detail: String? = nil
    var showsMark: Bool = true

    var body: some View {
        VStack(spacing: 14) {
            if showsMark {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [AlfredPalette.brass.opacity(0.22), AlfredPalette.brass.opacity(0)],
                                             center: .center, startRadius: 2, endRadius: 48))
                        .frame(width: 96, height: 96)
                    ClocheMark(width: 46)
                        .opacity(0.9)
                }
                .accessibilityHidden(true)
            }
            Text(text)
                .font(AlfredFont.voice(19))
                .foregroundStyle(AlfredPalette.parchment.opacity(0.9))
                .multilineTextAlignment(.center)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(AlfredFont.ui(14))
                    .foregroundStyle(AlfredPalette.mist)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .alfredEntrance()
    }
}

/// Three brass dots breathing in turn: Alfred is composing.
struct BrassDots: View {
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.85) {
                ForEach(0..<3, id: \.self) { i in
                    let v = reduceMotion ? 0.8 : (sin(t * 2.6 - Double(i) * 0.75) + 1) / 2
                    Circle()
                        .fill(AlfredPalette.brassGradient)
                        .frame(width: size, height: size)
                        .scaleEffect(0.62 + 0.38 * v)
                        .opacity(0.35 + 0.65 * v)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A primary brass capsule button label (use inside a `.borderless` button so
/// it behaves inside List rows).
struct BrassCapsule: View {
    var title: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title)
        }
        .font(AlfredFont.ui(14, weight: .semibold))
        .foregroundStyle(AlfredPalette.midnight)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AlfredPalette.brassGradient, in: Capsule())
        .shadow(color: AlfredPalette.brass.opacity(0.3), radius: 8, x: 0, y: 3)
    }
}

/// A quiet outlined capsule for secondary actions.
struct QuietCapsule: View {
    var title: String
    var tint: Color = AlfredPalette.parchment

    var body: some View {
        Text(title)
            .font(AlfredFont.ui(14, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
    }
}

// MARK: Motion helpers

/// Fades and rises (or slides) a view in once when it first appears.
/// With Reduce Motion on, it only fades.
struct AlfredEntrance: ViewModifier {
    let enabled: Bool
    let delay: Double
    let offset: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Bool

    init(enabled: Bool, delay: Double, offset: CGSize) {
        self.enabled = enabled
        self.delay = delay
        self.offset = offset
        _shown = State(initialValue: !enabled)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(shown || reduceMotion ? .zero : offset)
            .onAppear {
                guard !shown else { return }
                let animation = reduceMotion ? AlfredMotion.quick.delay(delay * 0.5) : AlfredMotion.spring.delay(delay)
                withAnimation(animation) { shown = true }
            }
    }
}

extension View {
    /// Fade and rise in on first appearance.
    func alfredEntrance(delay: Double = 0, rise: CGFloat = 12, enabled: Bool = true) -> some View {
        modifier(AlfredEntrance(enabled: enabled, delay: delay, offset: CGSize(width: 0, height: rise)))
    }

    /// Slide in from the trailing edge on first appearance (the owner's words).
    func alfredSlideIn(delay: Double = 0, enabled: Bool = true) -> some View {
        modifier(AlfredEntrance(enabled: enabled, delay: delay, offset: CGSize(width: 28, height: 4)))
    }

    /// Alfred's list row surface.
    func butlerRow() -> some View {
        self
            .listRowBackground(AlfredPalette.surface.opacity(0.62))
            .listRowSeparatorTint(AlfredPalette.brass.opacity(0.14))
    }
}

// MARK: UIKit chrome

/// Navigation and tab bar styling that SwiftUI can't reach directly: serif
/// titles in parchment, a translucent midnight tab bar with a brass hairline,
/// brass for the selected tab.
enum AlfredAppearance {
    static func apply() {
        let parchment = UIColor(AlfredPalette.parchment)
        let mist = UIColor(AlfredPalette.mist)
        let brass = UIColor(AlfredPalette.brass)
        let midnight = UIColor(AlfredPalette.midnight)

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: parchment,
            .font: serif(17, weight: .semibold),
        ]
        let largeAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: parchment,
            .font: serif(34, weight: .regular),
        ]

        let edge = UINavigationBarAppearance()
        edge.configureWithTransparentBackground()
        edge.titleTextAttributes = titleAttrs
        edge.largeTitleTextAttributes = largeAttrs

        let scrolled = UINavigationBarAppearance()
        scrolled.configureWithDefaultBackground()
        scrolled.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        scrolled.backgroundColor = midnight.withAlphaComponent(0.55)
        scrolled.shadowColor = brass.withAlphaComponent(0.16)
        scrolled.titleTextAttributes = titleAttrs
        scrolled.largeTitleTextAttributes = largeAttrs

        let navBar = UINavigationBar.appearance()
        navBar.standardAppearance = scrolled
        navBar.compactAppearance = scrolled
        navBar.scrollEdgeAppearance = edge
        navBar.tintColor = brass

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        tab.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        tab.backgroundColor = midnight.withAlphaComponent(0.72)
        tab.shadowColor = brass.withAlphaComponent(0.22)
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.normal.iconColor = mist
            item.normal.titleTextAttributes = [
                .foregroundColor: mist,
                .font: UIFont.systemFont(ofSize: 10, weight: .medium),
            ]
            item.selected.iconColor = brass
            item.selected.titleTextAttributes = [
                .foregroundColor: brass,
                .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            ]
        }
        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = tab
        tabBar.scrollEdgeAppearance = tab
        tabBar.tintColor = brass
        tabBar.unselectedItemTintColor = mist
    }

    static func serif(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }
}
