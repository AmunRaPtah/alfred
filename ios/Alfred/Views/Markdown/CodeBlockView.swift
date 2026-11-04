import SwiftUI

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(AlfredFont.ui(12).monospaced())
                    .foregroundStyle(AlfredPalette.mist)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    Haptics.tap()
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(AlfredFont.ui(12))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AlfredPalette.mist)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(AlfredPalette.midnight.opacity(0.4))

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(AlfredPalette.parchment)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
        }
        .background(AlfredPalette.slate.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AlfredPalette.brass.opacity(0.2)))
    }
}
