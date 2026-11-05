import Foundation
import Observation

/// Alfred has no session browser: one ongoing conversation ("primary") backs
/// Ask Alfred, and `sessions` (still fetched/cached) backs Inbox's history of
/// finished turns. There's no harness list (alfredd has exactly one harness)
/// and no cwd picker (every session opens in Alfred's own workspace).
@Observable
@MainActor
final class AppStore {
    private static let primaryKey = "alfred.primarySessionId"

    var config: ServerConfig
    private(set) var sessions: [Session]
    private(set) var listError: String?
    private(set) var lastSync: Date?
    private(set) var isRefreshing = false
    /// Last GET /brains answer; the static fallback until the first fetch.
    private(set) var brainCatalog: BrainCatalog = .fallback

    @ObservationIgnored private var chats: [String: ChatModel] = [:]
    @ObservationIgnored private var primarySessionId: String? {
        get { UserDefaults.standard.string(forKey: Self.primaryKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.primaryKey) }
    }

    init() {
        config = ServerConfig.load()
        sessions = DiskCache.loadSessions()
    }

    var api: APIClient { APIClient(config: config) }

    func updateConfig(_ c: ServerConfig) {
        let changed = c.normalizedURLString != config.normalizedURLString
        c.save()
        config = ServerConfig.load()
        for chat in chats.values { chat.updateConfig(config) }
        if changed {
            chats.values.forEach { $0.stop() }
            chats.removeAll()
            sessions = []
            primarySessionId = nil
            DiskCache.clearAll()
        }
    }

    // MARK: Sessions

    func refresh() async {
        guard config.isConfigured, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let list = try await api.sessions()
            sessions = list
            listError = nil
            lastSync = Date()
            DiskCache.saveSessions(list)
            for s in list { chats[s.id]?.mergeSession(s) }
        } catch is CancellationError {
        } catch {
            listError = APIClient.describe(error)
        }
    }

    func session(_ id: String) -> Session? { sessions.first { $0.id == id } }

    func upsert(_ s: Session) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.insert(s, at: 0) }
        sessions.sort { $0.updated > $1.updated }
        DiskCache.saveSessions(sessions)
    }

    func chat(for session: Session) -> ChatModel {
        if let c = chats[session.id] { return c }
        let c = ChatModel(session: session, store: self)
        chats[session.id] = c
        return c
    }

    /// The one ongoing conversation Ask Alfred shows. Resolves the cached
    /// primary session, falls back to the most recently updated session, and
    /// creates a new one if neither exists. Returns nil (with `listError` set)
    /// if creation itself fails; the UI shows a retry state rather than a
    /// placeholder session, since `Session` has no synthesized initializer to
    /// fabricate one from.
    func primaryChat() async -> ChatModel? {
        if let id = primarySessionId, let s = session(id) {
            return chat(for: s)
        }
        if config.isConfigured {
            await refresh()
            if let id = primarySessionId, let s = session(id) { return chat(for: s) }
            if let first = sessions.first {
                primarySessionId = first.id
                return chat(for: first)
            }
        }
        do {
            let s = try await api.createSession(.init(cwd: nil, permission: PermissionMode.bypass.rawValue, text: nil))
            upsert(s)
            primarySessionId = s.id
            return chat(for: s)
        } catch {
            listError = APIClient.describe(error)
            return nil
        }
    }

    /// Starts a brand new primary conversation, abandoning the old one (used
    /// by Today's "New conversation" action and Inbox's older-thread picker).
    /// `brain` picks the model for the new thread (GET /brains id); nil keeps
    /// the server default.
    func startNewPrimary(brain: String? = nil) async -> ChatModel? {
        // Create directly: primaryChat() would fall back to the most recent
        // session and reopen the old conversation instead of starting one.
        do {
            let s = try await api.createSession(.init(cwd: nil, permission: PermissionMode.bypass.rawValue,
                                                      text: nil, brain: brain))
            upsert(s)
            primarySessionId = s.id
            return chat(for: s)
        } catch {
            listError = APIClient.describe(error)
            return nil
        }
    }

    /// Refreshes `brainCatalog`; returns the error text on failure so the
    /// Models screen can show it (the cached catalog is kept).
    @discardableResult
    func refreshBrains() async -> String? {
        do {
            let c = try await api.brains()
            if !c.brains.isEmpty { brainCatalog = c }
            return nil
        } catch {
            return APIClient.describe(error)
        }
    }

    func switchPrimary(to id: String) {
        primarySessionId = id
    }
}
