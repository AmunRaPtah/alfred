import Foundation
import Observation

/// Coordinates "open this chat" requests that originate outside normal
/// navigation: a tapped notification's session_id, or a file handed to the
/// app via FileInbox. RootView observes `pendingSessionId` and switches to
/// Ask Alfred, loading that session as the primary conversation.
@Observable
final class Navigator {
    static let shared = Navigator()
    var pendingSessionId: String?
    var selectedTab: AppTab = .today

    func openSession(_ id: String) {
        pendingSessionId = id
        selectedTab = .askAlfred
    }
}

enum AppTab: Hashable {
    case today, askAlfred, inbox, settings
}
