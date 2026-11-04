import Foundation

/// Minimal block-level markdown parser. Inline syntax (bold, italics, code,
/// links) is left to AttributedString(markdown:). Pure parsing logic, ported
/// verbatim from Helm; nothing here is UI.
enum MarkdownBlock: Hashable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String, code: String)
    case listItem(indent: Int, marker: String, text: String)
    case quote(String)
    case table([String])
    case rule
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var para: [String] = []
        var quote: [String] = []
        var table: [String] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0

        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty { blocks.append(.table(table)); table = [] }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = fenceMarker(trimmed) {
                flush()
                let lang = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(fence) && t.trimmingCharacters(in: CharacterSet(charactersIn: String(fence.first!))).isEmpty { break }
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: lang, code: code.joined(separator: "\n")))
                i += 1
                continue
            }

            if trimmed.isEmpty { flush(); i += 1; continue }

            if trimmed.hasPrefix("|") {
                if !para.isEmpty || !quote.isEmpty { let t = table; table = []; flush(); table = t }
                table.append(trimmed)
                i += 1
                continue
            } else if !table.isEmpty {
                flush()
            }

            if let h = heading(trimmed) {
                flush(); blocks.append(h); i += 1; continue
            }
            if isRule(trimmed) {
                flush(); blocks.append(.rule); i += 1; continue
            }
            if let item = listItem(line) {
                flush(); blocks.append(item); i += 1; continue
            }
            if trimmed.hasPrefix(">") {
                if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            }
            // Continuation line of a list item.
            if para.isEmpty, quote.isEmpty, line.hasPrefix("  "),
               case .listItem(let ind, let m, let t)? = blocks.last {
                blocks[blocks.count - 1] = .listItem(indent: ind, marker: m, text: t + "\n" + trimmed)
                i += 1
                continue
            }
            if !quote.isEmpty { flush() }
            para.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    private static func fenceMarker(_ t: String) -> String? {
        for f in ["````", "```", "~~~"] where t.hasPrefix(f) { return f }
        return nil
    }

    private static func heading(_ t: String) -> MarkdownBlock? {
        let hashes = t.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = t.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ t: String) -> Bool {
        let s = t.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3, let c = s.first, "-*_".contains(c) else { return false }
        return s.allSatisfy { $0 == c }
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let body = line.dropFirst(indent)
        if let f = body.first, "-*+".contains(f), body.dropFirst().first == " " {
            var text = String(body.dropFirst(2))
            var marker = "\u{2022}"
            if text.hasPrefix("[ ] ") { marker = "\u{25CB}"; text = String(text.dropFirst(4)) }
            else if text.lowercased().hasPrefix("[x] ") { marker = "\u{2713}"; text = String(text.dropFirst(4)) }
            return .listItem(indent: indent / 2, marker: marker, text: text)
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = body.dropFirst(digits.count)
            if let p = after.first, p == "." || p == ")", after.dropFirst().first == " " {
                return .listItem(indent: indent / 2, marker: "\(digits).", text: String(after.dropFirst(2)))
            }
        }
        return nil
    }
}
