import SwiftUI

/// Alfred's palette and type system: a calm, refined butler aesthetic, not
/// Helm's. Named hex tokens, used everywhere instead of system colors so the
/// app reads as its own thing rather than a reskin.
enum AlfredPalette {
    static let midnight = Color(hex: 0x12192B)
    static let slate = Color(hex: 0x1E2740)
    static let brass = Color(hex: 0xC9A464)
    static let parchment = Color(hex: 0xF1EAD9)
    static let mist = Color(hex: 0x8B94AA)
    static let signal = Color(hex: 0x6FA287)
    static let caution = Color(hex: 0xC96A4A)
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

    static let title = voice(28, weight: .semibold)
    static let heading = voice(20, weight: .medium)
    static let body = ui(16)
    static let caption = ui(13)
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

/// The deep navy backdrop used behind every full-screen view.
struct AlfredBackground: View {
    var body: some View {
        LinearGradient(colors: [AlfredPalette.midnight, AlfredPalette.slate],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

/// Alfred's one recurring container: a quiet card with a hairline brass edge,
/// used for messages, reminders, and settings rows alike.
struct ButlerCard<Content: View>: View {
    var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(16)
            .background(AlfredPalette.slate.opacity(0.65))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AlfredPalette.brass.opacity(0.25), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A short, unobtrusive empty state: a line in Alfred's voice, nothing more.
struct ButlerEmptyState: View {
    var text: String
    var body: some View {
        Text(text)
            .font(AlfredFont.voice(17))
            .foregroundStyle(AlfredPalette.mist)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
    }
}
