import Foundation

/// Thin async/await REST client for alfredd (PROTOCOL.md). alfredd forks
/// helmd and keeps its session/event/REST shape unchanged; the differences
/// here are: no harnesses()/dirs()/box remote control (alfredd has exactly
/// one harness, "alfred", and no /box/*), plus the devices/reminders/notify
/// additions from PROTOCOL.md "Additions".
struct APIClient {
    var config: ServerConfig

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c, delegate: ClientCertDelegate.shared, delegateQueue: nil)
    }()

    // MARK: Sessions

    func health() async throws -> JSONValue {
        try await request("GET", "/health", auth: false)
    }

    func sessions() async throws -> [Session] {
        let v = try await request("GET", "/sessions")
        return list(v, key: "sessions").compactMap(Session.init(json:))
            .sorted { $0.updated > $1.updated }
    }

    func session(_ id: String) async throws -> Session {
        try decodeSession(try await request("GET", "/sessions/\(id)"))
    }

    struct NewSession {
        var cwd: String?
        var permission: String?
        var text: String?
    }

    /// Always creates an "alfred" harness session; Alfred has exactly one.
    func createSession(_ n: NewSession) async throws -> Session {
        var body: [String: JSONValue] = ["harness": .string("alfred")]
        if let c = n.cwd, !c.isEmpty { body["cwd"] = .string(c) }
        if let p = n.permission { body["permission"] = .string(p) }
        if let t = n.text, !t.isEmpty { body["text"] = .string(t) }
        return try decodeSession(try await request("POST", "/sessions", body: .object(body)))
    }

    func rename(_ id: String, title: String) async throws -> Session {
        try decodeSession(try await request("PATCH", "/sessions/\(id)", body: .object(["title": .string(title)])))
    }

    func delete(_ id: String, purge: Bool = false) async throws {
        _ = try await request("DELETE", "/sessions/\(id)", query: purge ? [URLQueryItem(name: "purge", value: "1")] : [])
    }

    func events(_ id: String, after: Int, limit: Int = 500) async throws -> [AlfredEvent] {
        let v = try await request("GET", "/sessions/\(id)/events", query: [
            URLQueryItem(name: "after", value: String(after)),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return list(v, key: "events").map(AlfredEvent.init(raw:))
    }

    func send(_ id: String, text: String, attachments: [String], clientId: String? = nil) async throws {
        var body: [String: JSONValue] = ["text": .string(text)]
        if let clientId { body["client_id"] = .string(clientId) }
        if !attachments.isEmpty { body["attachments"] = .array(attachments.map { .string($0) }) }
        _ = try await request("POST", "/sessions/\(id)/messages", body: .object(body))
    }

    func dequeue(_ id: String, queueId: String) async throws {
        _ = try await request("DELETE", "/sessions/\(id)/queue/\(queueId)")
    }

    /// Slash commands the "alfred" harness accepts (without the leading `/`).
    func commands(_ id: String) async throws -> [String] {
        try await request("GET", "/sessions/\(id)/commands")["commands"]?.stringArray ?? []
    }

    func interrupt(_ id: String) async throws {
        _ = try await request("POST", "/sessions/\(id)/interrupt")
    }

    func resume(_ id: String) async throws -> Session {
        let v = try await request("POST", "/sessions/\(id)/resume")
        if let s = Session(json: v) { return s }
        return try await session(id)
    }

    func upload(sessionId: String, data: Data, filename: String, mimeType: String) async throws -> String {
        let v = try await multipart("/upload", fields: ["session_id": sessionId],
                                    data: data, filename: filename, mimeType: mimeType)
        guard let path = v["path"]?.string ?? v.string, !path.isEmpty else {
            throw APIError.decoding("upload returned no path")
        }
        return path
    }

    private func multipart(_ path: String, fields: [String: String], data: Data,
                           filename: String, mimeType: String) async throws -> JSONValue {
        let boundary = "alfred-\(UUID().uuidString)"
        var body = Data()
        func line(_ s: String) { body.append(Data((s + "\r\n").utf8)) }
        for (name, value) in fields {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(name)\"")
            line("")
            line(value)
        }
        let safeName = filename.replacingOccurrences(of: "\"", with: "'")
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"")
        line("Content-Type: \(mimeType)")
        line("")
        body.append(data)
        line("")
        line("--\(boundary)--")

        var req = try makeRequest("POST", path, query: [], auth: true)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Documents can be tens of MB over a phone link; scale the timeout with size.
        req.timeoutInterval = max(120, Double(data.count) / 100_000)
        return try await perform(req, body: body)
    }

    // MARK: Push and reminders (PROTOCOL.md "Additions")

    func registerDevice(token: String, env: String, bundleId: String) async throws {
        _ = try await request("POST", "/devices", body: .object([
            "token": .string(token),
            "env": .string(env),
            "bundle_id": .string(bundleId),
        ]))
    }

    func unregisterDevice(token: String) async throws {
        _ = try await request("DELETE", "/devices/\(token)")
    }

    func reminders(after: Date? = nil) async throws -> [Reminder] {
        var query: [URLQueryItem] = []
        if let after {
            let f = ISO8601DateFormatter()
            query.append(URLQueryItem(name: "after", value: f.string(from: after)))
        }
        let v = try await request("GET", "/reminders", query: query)
        return list(v, key: "reminders").compactMap(Reminder.init(json:))
    }

    @discardableResult
    func sendPush(title: String, body: String, sessionId: String? = nil) async throws -> (sent: Int, failed: Int, configured: Bool) {
        var payload: [String: JSONValue] = ["title": .string(title), "body": .string(body)]
        if let sessionId { payload["session_id"] = .string(sessionId) }
        let v = try await request("POST", "/notify", body: .object(payload))
        return (v["sent"]?.int ?? 0, v["failed"]?.int ?? 0, v["configured"]?.bool ?? false)
    }

    func pushStatus() async throws -> PushStatus {
        PushStatus(json: try await request("GET", "/push/status"))
    }

    // MARK: Plumbing

    /// Accepts either a bare array or an object wrapping it (tolerant of either shape).
    private func list(_ v: JSONValue, key: String) -> [JSONValue] {
        if let a = v.array { return a }
        if let a = v[key]?.array { return a }
        if let a = v["items"]?.array { return a }
        return []
    }

    private func decodeSession(_ v: JSONValue) throws -> Session {
        if let s = Session(json: v) ?? v["session"].flatMap(Session.init(json:)) { return s }
        throw APIError.decoding("missing session id")
    }

    private func makeRequest(_ method: String, _ path: String, query: [URLQueryItem], auth: Bool) throws -> URLRequest {
        guard let base = config.baseURL else { throw APIError.notConfigured }
        guard var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError.badURL
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth {
            guard !config.token.isEmpty else { throw APIError.notConfigured }
            req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    @discardableResult
    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [],
                         body: JSONValue? = nil, auth: Bool = true) async throws -> JSONValue {
        var req = try makeRequest(method, path, query: query, auth: auth)
        var data: Data?
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            data = try JSONEncoder().encode(body)
        }
        return try await perform(req, body: data)
    }

    private func perform(_ req: URLRequest, body: Data?) async throws -> JSONValue {
        let result: (Data, URLResponse)
        do {
            if let body {
                result = try await Self.session.upload(for: req, from: body)
            } else {
                result = try await Self.session.data(for: req)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.transport(Self.describe(error))
        }
        let (data, resp) = result
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = JSONValue.parse(data).flatMap { $0["detail"]?.string ?? $0["error"]?.string }
                ?? String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(code, msg)
        }
        if data.isEmpty { return .null }
        return JSONValue.parse(data) ?? .string(String(data: data, encoding: .utf8) ?? "")
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .timedOut: return "Timed out. Is WireGuard connected?"
            case .cannotConnectToHost, .cannotFindHost: return "Can't reach the server. Is WireGuard on and alfredd running?"
            case .notConnectedToInternet: return "No network connection."
            case .networkConnectionLost: return "Connection lost."
            default: return e.localizedDescription
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
