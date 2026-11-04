import Foundation
import UniformTypeIdentifiers

/// A file chosen in the Files picker or handed over via "Open in Alfred", read into memory for upload.
struct PickedFile {
    var data: Data
    var filename: String
    var mimeType: String

    /// Reads a (possibly security-scoped) file URL. Returns nil if it can't be read.
    static func load(_ url: URL) -> PickedFile? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Coordinated read so iCloud Drive files that aren't downloaded yet get fetched first.
        var data: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { data = try? Data(contentsOf: $0) }
        guard let data else { return nil }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return PickedFile(data: data, filename: url.lastPathComponent, mimeType: mime)
    }

    static func icon(for filename: String) -> String {
        guard let t = UTType(filenameExtension: (filename as NSString).pathExtension) else { return "doc" }
        if t.conforms(to: .image) { return "photo" }
        if t.conforms(to: .pdf) { return "doc.richtext" }
        if t.conforms(to: .movie) || t.conforms(to: .audio) { return "play.rectangle" }
        if t.conforms(to: .archive) { return "doc.zipper" }
        if t.conforms(to: .sourceCode) || t.conforms(to: .plainText) { return "doc.plaintext" }
        return "doc"
    }
}
