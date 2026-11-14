import Foundation

/// Minimal JSON value so envelope `data` can carry arbitrary payloads and still round-trip.
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
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

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    public var doubleValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
}

public enum EnvelopeType: String, Codable, Sendable {
    case weight, meal
    case activityDay = "activity_day", nutritionDay = "nutrition_day", workout
}

/// What goes inside the ciphertext. Mirrors `ENVELOPE_VERSION` handling in `sync.py`.
public struct Envelope: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public enum Op: String, Codable, Sendable { case upsert, delete }

    public var v: Int
    public var type: EnvelopeType
    public var op: Op
    public var id: String
    public var version: Int
    public var updatedAt: Int
    public var data: JSONValue?

    enum CodingKeys: String, CodingKey { case v, type, op, id, version, updatedAt = "updated_at", data }

    public init(type: EnvelopeType, op: Op, id: String, version: Int, updatedAt: Int, data: JSONValue? = nil) {
        self.v = Self.currentVersion; self.type = type; self.op = op; self.id = id
        self.version = version; self.updatedAt = updatedAt; self.data = data
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> Envelope {
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        guard env.v == currentVersion, (1...128).contains(env.id.count), env.version >= 0,
              env.op == .delete || env.data != nil else { throw CryptoError.badEncoding }
        return env
    }
}
