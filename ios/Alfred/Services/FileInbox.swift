import Foundation
import Observation

/// Files handed to Alfred by another app ("Open in Alfred" / share sheet),
/// waiting to be attached to a chat. alfredd has no /box, so, unlike Helm,
/// which uploaded these to a chosen box directory, RootView attaches each
/// incoming file to the current (or a freshly created) primary Alfred
/// conversation via POST /upload, then switches to Ask Alfred so the attach
/// is visible in the composer before sending.
@Observable
final class FileInbox {
    static let shared = FileInbox()
    var pending: [PickedFile] = []

    /// Routes an incoming URL: certificates go to CertInbox, anything else is queued for upload.
    func receive(_ url: URL) {
        if ["p12", "pfx"].contains(url.pathExtension.lowercased()) {
            CertInbox.shared.receive(url)
            return
        }
        guard url.isFileURL, let f = PickedFile.load(url) else { return }
        pending.append(f)
        // iOS copies the document into Documents/Inbox; it's in memory now.
        try? FileManager.default.removeItem(at: url)
    }
}
