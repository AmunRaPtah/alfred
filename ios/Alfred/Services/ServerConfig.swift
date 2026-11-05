import Foundation

/// Server URL (UserDefaults) and bearer token (Keychain). Alfred's own
/// namespacing so it never collides with Helm on the same phone.
struct ServerConfig: Equatable {
    static let defaultURL = "https://alfred.178-18-250-254.sslip.io"
    private static let urlKey = "alfred.serverURL"
    private static let tokenAccount = "alfred.token"

    var urlString: String
    var token: String

    private static let embeddedAppliedKey = "alfred.embeddedApplied"

    static func load() -> ServerConfig {
        applyEmbeddedOnce()
        return ServerConfig(
            urlString: UserDefaults.standard.string(forKey: urlKey) ?? defaultURL,
            token: Keychain.read(tokenAccount) ?? ""
        )
    }

    /// A private build ships its URL and token; write them once so the app
    /// works on first launch, after which Settings edits win.
    private static func applyEmbeddedOnce() {
        guard let e = EmbeddedConfig.shared,
              !UserDefaults.standard.bool(forKey: embeddedAppliedKey) else { return }
        if let u = e.url, !u.isEmpty { UserDefaults.standard.set(u, forKey: urlKey) }
        if let t = e.token, !t.isEmpty { Keychain.write(t, account: tokenAccount) }
        UserDefaults.standard.set(true, forKey: embeddedAppliedKey)
    }

    func save() {
        UserDefaults.standard.set(normalizedURLString, forKey: Self.urlKey)
        Keychain.write(token.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.tokenAccount)
    }

    var isConfigured: Bool { baseURL != nil && !token.isEmpty }

    var normalizedURLString: String {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty, !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    var baseURL: URL? {
        guard let u = URL(string: normalizedURLString), u.host != nil else { return nil }
        return u
    }
}
