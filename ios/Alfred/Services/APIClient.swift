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

    /// Long idle timeout for /voice/turn: the first sentence can take a while
    /// when the brain is thinking, and SSE has no keepalive guarantee.
    private static let streamSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 300
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

    // MARK: Voice and TTS

    /// One server-sent event from POST /voice/turn: `sentence`, `action`,
    /// `done` or `error`, with its JSON data payload.
    struct VoiceTurnEvent {
        var name: String
        var data: JSONValue
    }

    /// POST /voice/turn, parsed incrementally as SSE. The stream finishes
    /// when the server closes it; cancelling the consumer cancels the request.
    func voiceTurn(sessionId: String, text: String, voice: String?) -> AsyncThrowingStream<VoiceTurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var payload: [String: JSONValue] = ["session_id": .string(sessionId), "text": .string(text)]
                    if let voice, !voice.isEmpty { payload["voice"] = .string(voice) }
                    var req = try makeRequest("POST", "/voice/turn", query: [], auth: true)
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONEncoder().encode(JSONValue.object(payload))
                    let (bytes, resp) = try await Self.streamSession.bytes(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(code) else {
                        var body = Data()
                        for try await b in bytes {
                            body.append(b)
                            if body.count > 4096 { break }
                        }
                        let msg = JSONValue.parse(body).flatMap { $0["detail"]?.string ?? $0["error"]?.string }
                            ?? String(data: body, encoding: .utf8) ?? ""
                        throw APIError.http(code, msg)
                    }
                    // Byte-level parse: AsyncBytes.lines drops blank lines,
                    // which are exactly the SSE event separators.
                    var line = Data()
                    var eventName = "message"
                    var dataLines: [String] = []
                    func dispatch() {
                        defer { eventName = "message"; dataLines = [] }
                        guard !dataLines.isEmpty else { return }
                        let raw = dataLines.joined(separator: "\n")
                        let value = JSONValue.parse(Data(raw.utf8)) ?? .string(raw)
                        continuation.yield(VoiceTurnEvent(name: eventName, data: value))
                    }
                    func handle(_ l: String) {
                        if l.isEmpty { dispatch(); return }
                        if l.hasPrefix(":") { return }
                        let field: Substring
                        var value: Substring
                        if let colon = l.firstIndex(of: ":") {
                            field = l[l.startIndex..<colon]
                            value = l[l.index(after: colon)...]
                            if value.hasPrefix(" ") { value = value.dropFirst() }
                        } else {
                            field = Substring(l)
                            value = ""
                        }
                        switch field {
                        case "event": eventName = String(value)
                        case "data": dataLines.append(String(value))
                        default: break
                        }
                    }
                    for try await b in bytes {
                        if b == UInt8(ascii: "\n") {
                            if line.last == UInt8(ascii: "\r") { line.removeLast() }
                            handle(String(decoding: line, as: UTF8.self))
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(b)
                        }
                    }
                    if !line.isEmpty { handle(String(decoding: line, as: UTF8.self)) }
                    dispatch()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let e as URLError where e.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch let e as APIError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: APIError.transport(Self.describe(error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// POST /tts: synthesized speech as audio/mpeg bytes. 502 when the TTS
    /// host is down.
    func tts(text: String, voice: String? = nil, engine: String? = nil, speed: Double? = nil) async throws -> Data {
        var payload: [String: JSONValue] = ["text": .string(text)]
        if let voice, !voice.isEmpty { payload["voice"] = .string(voice) }
        if let engine, !engine.isEmpty { payload["engine"] = .string(engine) }
        if let speed { payload["speed"] = .number(speed) }
        var req = try makeRequest("POST", "/tts", query: [], auth: true)
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try await performRaw(req, body: try JSONEncoder().encode(JSONValue.object(payload)))
        guard !data.isEmpty else { throw APIError.decoding("empty audio") }
        return data
    }

    func ttsVoices() async throws -> TTSVoices {
        TTSVoices(json: try await request("GET", "/tts/voices"))
    }

    // MARK: Outbox (PROTOCOL.md "Outbox")

    func outbox(status: String? = "pending") async throws -> [OutboxItem] {
        let query = status.map { [URLQueryItem(name: "status", value: $0)] } ?? []
        let v = try await request("GET", "/outbox", query: query)
        return list(v, key: "outbox").compactMap(OutboxItem.init(json:))
    }

    /// Really sends the email. alfredd 403s approvals that don't come from
    /// the app (outbox.py check_approval_allowed); the app marks itself with
    /// `X-Alfred-Route: public`, which is what that gate accepts.
    @discardableResult
    func approveOutbox(id: String) async throws -> OutboxItem? {
        var req = try makeRequest("POST", "/outbox/\(id)/approve", query: [], auth: true)
        req.setValue("public", forHTTPHeaderField: "X-Alfred-Route")
        return OutboxItem(json: try await perform(req, body: nil))
    }

    @discardableResult
    func rejectOutbox(id: String) async throws -> OutboxItem? {
        OutboxItem(json: try await request("POST", "/outbox/\(id)/reject"))
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
        let data = try await performRaw(req, body: body)
        if data.isEmpty { return .null }
        return JSONValue.parse(data) ?? .string(String(data: data, encoding: .utf8) ?? "")
    }

    private func performRaw(_ req: URLRequest, body: Data?) async throws -> Data {
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
        return data
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
