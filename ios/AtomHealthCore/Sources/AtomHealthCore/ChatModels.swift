import Foundation

public struct ChatButton: Codable, Equatable, Hashable, Sendable {
    public var text: String
    public var data: String
    public init(text: String, data: String) { self.text = text; self.data = data }
}

/// A graphic the Mac attached to a bot message (`visuals` in `phonechat.py` / `visuals.py`): a gauge or ring (`value`
/// against `max`, coloured by `status`) or a bar / line chart of `points` with an optional `target` line.
public struct ChatVisual: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case gauge, ring, bars, line }
    public enum Status: String, Codable, Sendable { case ok, warn, over }
    public struct Point: Codable, Equatable, Hashable, Sendable {
        public var label: String
        public var value: Double
        public init(label: String, value: Double) { self.label = label; self.value = value }
    }
    public var kind: Kind
    public var label: String
    public var value: Double
    public var max: Double
    public var unit: String
    public var status: Status?
    public var points: [Point]
    public var target: Double?

    public init(kind: Kind = .gauge, label: String, value: Double = 0, max: Double = 1, unit: String = "", status: Status? = nil,
                points: [Point] = [], target: Double? = nil) {
        self.kind = kind; self.label = label; self.value = value; self.max = max; self.unit = unit
        self.status = status; self.points = points; self.target = target
    }

    // Tolerant decoding: a chat saved by an older build (gauges only, no kind / points) must still load.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .gauge
        label = try c.decode(String.self, forKey: .label)
        value = try c.decodeIfPresent(Double.self, forKey: .value) ?? 0
        max = try c.decodeIfPresent(Double.self, forKey: .max) ?? 1
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        status = try c.decodeIfPresent(Status.self, forKey: .status)
        points = try c.decodeIfPresent([Point].self, forKey: .points) ?? []
        target = try c.decodeIfPresent(Double.self, forKey: .target)
    }

    /// 0...1 for a bar or ring; the number itself may exceed the limit.
    public var fraction: Double { max > 0 ? Swift.min(1, Swift.max(0, value / max)) : 0 }

    /// Reads the wire form; anything malformed is skipped.
    static func parse(_ v: JSONValue?) -> [ChatVisual]? {
        let list: [ChatVisual] = (v?.arrayValue ?? []).prefix(8).compactMap { d in
            guard let kind = d["type"]?.stringValue.flatMap(Kind.init(rawValue:)), let label = d["label"]?.stringValue else { return nil }
            let unit = d["unit"]?.stringValue ?? ""
            switch kind {
            case .gauge, .ring:
                guard let value = d["value"]?.doubleValue, let mx = d["max"]?.doubleValue, mx > 0, value >= 0 else { return nil }
                return ChatVisual(kind: kind, label: label, value: value, max: mx, unit: unit,
                                  status: d["status"]?.stringValue.flatMap(Status.init(rawValue:)))
            case .bars, .line:
                let pts: [Point] = (d["points"]?.arrayValue ?? []).prefix(31).compactMap { p in
                    guard let l = p["label"]?.stringValue, let x = p["value"]?.doubleValue else { return nil }
                    return Point(label: l, value: x)
                }
                guard pts.count >= 2 else { return nil }
                return ChatVisual(kind: kind, label: label, unit: unit, points: pts, target: d["target"]?.doubleValue)
            }
        }
        return list.isEmpty ? nil : list
    }
}

public struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case user, bot }
    /// Telegram-style ticks: waiting to leave the phone, handed to the relay, answered by the Mac.
    public enum Delivery: String, Codable, Sendable { case sending, sent, answered }

    public var id: String                 // "u-<uuid>" for the user, "m<n>" for the bot (n = the Mac's message id)
    public var role: Role
    public var text: String               // plain text for the user, Telegram-HTML subset for the bot
    public var buttons: [[ChatButton]]
    public var date: Date
    public var edited: Bool
    public var mid: Int?                  // the Mac's message id, needed to answer a button tap
    public var photos: [String]           // file names in the chat media folder
    public var delivery: Delivery
    public var visuals: [ChatVisual]?     // optional so chats saved by older builds still load

    public init(id: String, role: Role, text: String, buttons: [[ChatButton]] = [], date: Date = Date(),
                edited: Bool = false, mid: Int? = nil, photos: [String] = [], delivery: Delivery = .sending,
                visuals: [ChatVisual]? = nil) {
        self.id = id; self.role = role; self.text = text; self.buttons = buttons; self.date = date
        self.edited = edited; self.mid = mid; self.photos = photos; self.delivery = delivery; self.visuals = visuals
    }
}

public struct ChatSnapshot: Equatable, Sendable {
    public var messages: [ChatMessage] = []
    public var typingUntil: Date?
    public var toast: String?
    public var unread = 0
    /// When anything from the Mac (a reply, "typing", a ping answer) last arrived, and what the Mac said about its AI backend.
    public var heardAt: Date?
    public var aiReady: Bool?
    public init() {}

    public func isTyping(now: Date = Date()) -> Bool { (typingUntil ?? .distantPast) > now }
    /// True while the user is waiting for the Mac: their last message has no answer yet.
    public var awaitingReply: Bool {
        guard let last = messages.last else { return false }
        return last.role == .user && last.delivery != .answered
    }
}

/// How the phone talks to the Mac's bot. Mirrors `phonechat.py` (the contract is documented there).
public enum ChatWire {
    /// Raw JPEG bytes per chunk: a sealed record may carry ~64 KB of ciphertext, base64 inflates by a third.
    public static let chunkSize = 40_000
    public static let maxPhotos = 10

    static func uid() -> String { UUID().uuidString.lowercased() }

    public static func text(_ s: String) -> LocalChange {
        LocalChange(type: .chatIn, id: "t-\(uid())", op: .upsert, data: .object(["kind": .string("text"), "text": .string(s),
            "sent_at": .number(Date().timeIntervalSince1970.rounded())]))
    }

    /// Chunks of one photo, then (in the same queue, so in order) nothing else: `message` ties them together.
    public static func photoChunks(photoID: String, jpeg: Data) -> [LocalChange] {
        let parts = PhotoPrep.chunks(jpeg, size: chunkSize)
        return parts.enumerated().map { i, d in
            LocalChange(type: .chatIn, id: "p-\(photoID)-\(i)", op: .upsert, data: .object([
                "kind": .string("photo"), "photo_id": .string(photoID), "idx": .number(Double(i)),
                "n": .number(Double(parts.count)), "b64": .string(d.base64EncodedString())]))
        }
    }

    public static func message(text: String, photoIDs: [String]) -> LocalChange {
        LocalChange(type: .chatIn, id: "m-\(uid())", op: .upsert, data: .object([
            "kind": .string("message"), "text": .string(text), "photos": .array(photoIDs.map(JSONValue.string)),
            "sent_at": .number(Date().timeIntervalSince1970.rounded())]))
    }

    public static func ping() -> LocalChange {
        LocalChange(type: .chatIn, id: "g-\(uid())", op: .upsert, data: .object(["kind": .string("ping")]))
    }

    public static func callback(data: String, messageID: Int) -> LocalChange {
        LocalChange(type: .chatIn, id: "c-\(uid())", op: .upsert, data: .object([
            "kind": .string("callback"), "data": .string(data), "msg_id": .number(Double(messageID))]))
    }
}

/// What the header of the chat says about the Mac and its bot. Pure, so it is unit-tested.
public enum ChatStatus: Equatable, Sendable {
    case offline              // this phone cannot reach the relay
    case checking             // asked the Mac, no answer yet
    case macUnreachable       // the relay is fine but the Mac has not answered (asleep or off)
    case waiting              // the Mac is there; the answer to the user's last message has not come yet
    case working              // the bot is typing or analysing
    case online(aiReady: Bool?)

    public static let unreachableAfter: TimeInterval = 25
    public static let freshFor: TimeInterval = 90

    /// - Parameters:
    ///   - pingSentAt: the oldest ping that has not been answered yet, or the latest answered one
    ///   - relayOK: the last sync with the relay succeeded
    public static func derive(chat: ChatSnapshot, pingSentAt: Date?, relayOK: Bool, now: Date = Date()) -> ChatStatus {
        guard relayOK else { return .offline }
        if chat.isTyping(now: now) { return .working }
        let probe = [pingSentAt, chat.awaitingReply ? chat.messages.last?.date : nil].compactMap { $0 }.max()
        let fresh = chat.heardAt.map { now.timeIntervalSince($0) < freshFor } ?? false
        let heardSinceProbe = probe.map { p in chat.heardAt.map { $0 >= p } ?? false } ?? fresh
        if heardSinceProbe { return chat.awaitingReply ? .waiting : .online(aiReady: chat.aiReady) }
        if let p = probe, now.timeIntervalSince(p) >= unreachableAfter { return .macUnreachable }
        if fresh, !chat.awaitingReply { return .online(aiReady: chat.aiReady) }
        return .checking
    }
}
