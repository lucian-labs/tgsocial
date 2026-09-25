// Protocol — a JSON value, read the way the web reference reads it. Pure Swift.
//
// PROTOCOL §12's rules are written against what the AppView actually sends, and what it sends is
// only loosely typed: a `createdAt` that is not a string, a `reason` with no `indexedAt`, a record
// with fields a lexicon added last month. `web/js/protocol.js` reads all of that with optional
// chaining and never throws; the vectors in `docs/card-vectors.json` hold both clients to the same
// answers on the same bytes. Decoding into strict structs would turn a malformed field into a
// thrown page and a missing source — §12.5 rule 6 for a reason that is not a server being down —
// so the §12 layer reads this instead, and the view models are built from it after admission.

import Foundation

public enum JSONValue: Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        self = .object(try c.decode([String: JSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public static func parse(_ data: Data) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: data) }

    public func data() -> Data { (try? JSONEncoder().encode(self)) ?? Data("null".utf8) }

    /// `value?.key` — `.null` for anything that is not an object holding the key.
    public subscript(_ key: String) -> JSONValue {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var number: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var int: Int? { number.flatMap { $0.isFinite ? Int(exactly: $0.rounded(.towardZero)) : nil } }
    public var array: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    public var isNull: Bool { self == .null }
    /// JavaScript truthiness for the one place the reference tests it (`if (entry?.reason)`).
    public var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }
}
