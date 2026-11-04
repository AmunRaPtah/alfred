import Foundation

enum APIError: LocalizedError {
    case notConfigured
    case badURL
    case http(Int, String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set the server URL and token in Settings."
        case .badURL: return "The server URL is not valid."
        case .http(401, _), .http(403, _): return "The server rejected the token (unauthorized)."
        case .http(409, _): return "The session is busy. Try again in a moment."
        case .http(let code, let body):
            let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return b.isEmpty ? "Server error \(code)." : "Server error \(code): \(b.prefix(200))"
        case .decoding(let m): return "Unexpected response: \(m)"
        case .transport(let m): return m
        }
    }

    var statusCode: Int? {
        if case .http(let c, _) = self { return c }
        return nil
    }
}
