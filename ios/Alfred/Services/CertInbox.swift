import Foundation
import Observation

/// A .p12 waiting for its password, from the file picker, the clipboard, or
/// "Open in Alfred" from another app. Settings shows the password field while set.
@Observable
final class CertInbox {
    static let shared = CertInbox()
    var pending: Data?

    /// Reads a .p12 handed to the app by another app (share sheet / Open in).
    func receive(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url), !data.isEmpty { pending = data }
    }

    /// Decodes a base64 .p12 copied as text. Tolerates whitespace and PEM-style armor lines.
    static func decodePasted(_ text: String) -> Data? {
        let body = text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .filter { !$0.isWhitespace }
        guard !body.isEmpty else { return nil }
        return Data(base64Encoded: body)
    }
}
