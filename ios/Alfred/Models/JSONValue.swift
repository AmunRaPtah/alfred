import Foundation

/// A loss-free, crash-free JSON value. Everything the server sends is decoded
/// into this first, then read through tolerant accessors, so a missing field,
/// a wrong type or an unknown event never throws.
enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var isNull: Bool { if case .null = self { return true }; return false }

    /// Lenient string: numbers and bools are stringified, objects/arrays are
    /// pretty-printed JSON, null is nil.
    var string: String? {
        switch self {
        case .null: return nil
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let d):
            if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        case .array, .object:
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            guard let data = try? enc.encode(self) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    var double: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    var int: Int? {
        guard let d = double, d.isFinite else { return nil }
        return Int(d)
    }

    var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .string(let s): return ["true", "1", "yes"].contains(s.lowercased())
        default: return nil
        }
    }

    var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var stringArray: [String] {
        if let a = array { return a.compactMap { $0.string } }
        if let s = string, !s.isEmpty { return [s] }
        return []
    }

    static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
