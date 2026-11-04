import SwiftUI

struct MarkdownView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let t):
            InlineText(t)
        case .heading(let level, let t):
            InlineText(t)
                .font(level <= 1 ? AlfredFont.voice(19, weight: .semibold) : level == 2 ? AlfredFont.voice(17, weight: .medium) : AlfredFont.ui(15, weight: .semibold))
                .padding(.top, level <= 2 ? 4 : 0)
        case .code(let lang, let code):
            CodeBlockView(language: lang, code: code)
        case .listItem(let indent, let marker, let t):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .foregroundStyle(AlfredPalette.brass)
                    .monospacedDigit()
                    .frame(minWidth: 14, alignment: .trailing)
                InlineText(t)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let t):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(AlfredPalette.brass.opacity(0.5)).frame(width: 3)
                InlineText(t).foregroundStyle(AlfredPalette.mist)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let rows):
            TableBlock(rows: rows)
        case .rule:
            Divider().overlay(AlfredPalette.brass.opacity(0.2)).padding(.vertical, 4)
        }
    }
}

struct InlineText: View {
    let source: String
    init(_ source: String) { self.source = source }

    var body: some View {
        Text(Self.attributed(source))
            .fixedSize(horizontal: false, vertical: true)
    }

    static func attributed(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }
}

private struct TableBlock: View {
    let rows: [String]

    var body: some View {
        let parsed = rows
            .filter { row in !row.replacingOccurrences(of: "|", with: "").allSatisfy { "-: ".contains($0) } }
            .map { row in
                row.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(parsed.enumerated()), id: \.offset) { idx, cells in
                    GridRow {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, c in
                            Text(InlineText.attributed(c))
                                .font(idx == 0 ? AlfredFont.ui(12, weight: .semibold) : AlfredFont.ui(12))
                                .foregroundStyle(AlfredPalette.parchment)
                                .fixedSize()
                        }
                    }
                    if idx == 0 { Divider().overlay(AlfredPalette.brass.opacity(0.25)) }
                }
            }
            .padding(10)
        }
        .background(AlfredPalette.slate.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
