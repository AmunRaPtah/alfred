import Foundation
import Observation

/// WebSocket tail of one session's events (PROTOCOL.md "WebSocket").
/// Connects with `after=lastSeq`, reconnects with exponential backoff and
/// resumes from the last seq it delivered. Falls back to REST catch-up when
/// the socket keeps failing. Unchanged from Helm: pure protocol plumbing.
@Observable
@MainActor
final class SessionStream {
    enum Phase: Equatable {
        case idle
        case connecting
        case live
        case waiting(seconds: Int)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastError: String?
    private(set) var lastSeq: Int = 0

    @ObservationIgnored let sessionId: String
    @ObservationIgnored var config: ServerConfig
    /// Called on the main actor with batches of events, in seq order.
    @ObservationIgnored var onEvents: (([AlfredEvent]) -> Void)?

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var buffer: [AlfredEvent] = []
    @ObservationIgnored private var flushScheduled = false

    private static let urlSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c, delegate: ClientCertDelegate.shared, delegateQueue: nil)
    }()

    init(sessionId: String, config: ServerConfig) {
        self.sessionId = sessionId
        self.config = config
    }

    var isRunning: Bool { runTask != nil }

    func start(after seq: Int) {
        lastSeq = max(lastSeq, seq)
        guard runTask == nil else { return }
        runTask = Task { [weak self] in await self?.run() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        flush()
        phase = .idle
    }

    func reconnectNow() {
        stop()
        start(after: lastSeq)
    }

    /// Send a raw frame over the socket (protocol allows message/interrupt here).
    func sendFrame(_ value: JSONValue) async -> Bool {
        guard let socket, phase == .live,
              let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return false }
        do { try await socket.send(.string(text)); return true } catch { return false }
    }

    // MARK: Loop

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            phase = .connecting
            let receivedSomething = await connectOnce()
            if Task.isCancelled { break }
            if receivedSomething { attempt = 0 }
            attempt += 1
            if attempt >= 2 { await restCatchUp() }
            if Task.isCancelled { break }
            let base = min(30.0, pow(2.0, Double(attempt - 1)))
            let delay = base * Double.random(in: 0.8...1.2)
            phase = .waiting(seconds: max(1, Int(delay.rounded())))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// Returns true if the connection was established (pong or any frame).
    private func connectOnce() async -> Bool {
        guard let req = makeRequest() else {
            lastError = "Server not configured"
            return false
        }
        let ws = Self.urlSession.webSocketTask(with: req)
        ws.maximumMessageSize = 32 * 1024 * 1024
        socket = ws
        ws.resume()

        var opened = false
        let heartbeat = Task { [weak self] in
            // First pong confirms the socket is open; later ones detect dead links.
            while !Task.isCancelled {
                let ok = await Self.ping(ws)
                guard let self else { return }
                if ok {
                    if self.phase != .live { self.phase = .live; self.lastError = nil }
                } else {
                    ws.cancel(with: .abnormalClosure, reason: nil)
                    return
                }
                try? await Task.sleep(nanoseconds: 25_000_000_000)
            }
        }
        defer {
            heartbeat.cancel()
            ws.cancel(with: .goingAway, reason: nil)
            if socket === ws { socket = nil }
            flush()
        }

        while !Task.isCancelled {
            do {
                let msg = try await ws.receive()
                opened = true
                if phase != .live { phase = .live; lastError = nil }
                switch msg {
                case .string(let s): handle(Data(s.utf8))
                case .data(let d): handle(d)
                @unknown default: break
                }
            } catch {
                if !Task.isCancelled { lastError = APIClient.describe(error) }
                break
            }
        }
        return opened || phase == .live
    }

    private static func ping(_ ws: URLSessionWebSocketTask) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = OnceFlag()
            ws.sendPing { error in
                if once.claim() { cont.resume(returning: error == nil) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                if once.claim() { cont.resume(returning: false) }
            }
        }
    }

    private func makeRequest() -> URLRequest? {
        guard let base = config.baseURL,
              var comps = URLComponents(url: base.appendingPathComponent("/sessions/\(sessionId)/stream"),
                                        resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        comps.queryItems = [URLQueryItem(name: "after", value: String(lastSeq))]
        // Query token only over plain ws (wg0); the public route accepts the header only.
        if comps.scheme == "ws" { comps.queryItems?.append(URLQueryItem(name: "token", value: config.token)) }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        return req
    }

    // MARK: Frames

    private func handle(_ data: Data) {
        guard let value = JSONValue.parse(data) else { return }
        // Tolerate servers that batch frames as arrays.
        let frames = value.array ?? [value]
        for f in frames {
            let e = AlfredEvent(raw: f)
            if e.type == "ping" || e.type == "pong" { continue }
            enqueue(e)
        }
    }

    private func enqueue(_ e: AlfredEvent) {
        if let s = e.seq {
            if s <= lastSeq { return }
            lastSeq = s
        }
        buffer.append(e)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll()
        onEvents?(batch)
    }

    private func restCatchUp() async {
        let api = APIClient(config: config)
        for _ in 0..<20 {
            guard !Task.isCancelled,
                  let batch = try? await api.events(sessionId, after: lastSeq) else { return }
            batch.forEach(enqueue)
            flush()
            if batch.count < 500 { return }
        }
    }
}

/// Thread-safe one-shot flag for resuming a continuation exactly once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
