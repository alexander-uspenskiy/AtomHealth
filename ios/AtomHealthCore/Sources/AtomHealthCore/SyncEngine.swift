import Foundation

/// The relay operations the engine needs; `RelayClient` conforms, tests use an in-memory fake.
public protocol RelayAPI: Sendable {
    func push(_ records: [RecordCrypto.Sealed]) async throws
    func pull(since: Int, limit: Int) async throws -> PullResult
    func ack(cursor: Int) async throws
}
extension RelayClient: RelayAPI {}

/// A change that originated on this phone (from HealthKit or the user), waiting to be sent.
public struct LocalChange: Equatable, Sendable {
    public var type: EnvelopeType
    public var id: String
    public var op: Envelope.Op
    public var data: JSONValue?
    public init(type: EnvelopeType, id: String, op: Envelope.Op, data: JSONValue? = nil) {
        self.type = type; self.id = id; self.op = op; self.data = data
    }
}

/// Persistent state. The iOS app backs this with a file/SQLite store; tests use `InMemoryStateStore`.
public protocol SyncStateStore: Sendable {
    func cursor() async -> Int
    func setCursor(_ v: Int) async
    func version(of type: EnvelopeType, id: String) async -> Int?
    func setVersion(_ v: Int, of type: EnvelopeType, id: String) async
    func pending() async -> [LocalChange]
    func removePending(count: Int) async
}

/// Where inbound data lands (HealthKit on the phone). Throwing means "not applied": the cursor then stays put.
public protocol InboundSink: Sendable {
    func apply(_ env: Envelope) async throws
}

public struct SyncReport: Equatable, Sendable {
    public var pulled = 0, pushed = 0, stale = 0, bad = 0
}

/// One pull then one push, with the same rules as `sync.py` / `relay.py`:
/// - every record is authenticated against (device id, record id); failures are skipped and counted
/// - per-entity version, last-writer-wins: an envelope is applied only if its version is newer than any seen
/// - deletes are applied like upserts (tombstones) and versioned
/// - the pull cursor advances only after a page has been applied; local changes leave the outbox only after a successful push
/// - the phone accepts weight and meal (the Mac's outbound types); anything else is skipped
public actor SyncEngine {
    public static let inboundTypes: Set<EnvelopeType> = [.weight, .meal]
    static let pullPage = 100

    let deviceID: String
    let key: Data
    let relay: RelayAPI
    let store: SyncStateStore
    let sink: InboundSink
    let clock: @Sendable () -> Date

    public init(deviceID: String, key: Data, relay: RelayAPI, store: SyncStateStore, sink: InboundSink,
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.deviceID = deviceID; self.key = key; self.relay = relay
        self.store = store; self.sink = sink; self.clock = clock
    }

    public func cycle() async throws -> SyncReport {
        var report = SyncReport()
        try await pull(&report)
        try await push(&report)
        return report
    }

    func pull(_ report: inout SyncReport) async throws {
        var since = await store.cursor()
        while true {
            let page = try await relay.pull(since: since, limit: Self.pullPage)
            for rec in page.records {
                guard let env = try? Envelope.decode(RecordCrypto.open(
                    nonce: rec.nonce, ciphertext: rec.ciphertext, key: key,
                    deviceID: rec.device_id, recordID: rec.record_id)),
                      Self.inboundTypes.contains(env.type) else { report.bad += 1; continue }
                if let seen = await store.version(of: env.type, id: env.id), seen >= env.version {
                    report.stale += 1; continue
                }
                try await sink.apply(env)
                await store.setVersion(env.version, of: env.type, id: env.id)
                report.pulled += 1
            }
            if page.next_seq > since {
                await store.setCursor(page.next_seq)
                try await relay.ack(cursor: page.next_seq)
            }
            if !page.has_more || page.next_seq <= since { break }
            since = page.next_seq
        }
    }

    func push(_ report: inout SyncReport) async throws {
        let changes = await store.pending()
        guard !changes.isEmpty else { return }
        let nowMs = Int(clock().timeIntervalSince1970 * 1000)
        var versions: [String: Int] = [:]   // a second change to the same entity in one batch still increases
        var sealed: [RecordCrypto.Sealed] = []
        var applied: [(LocalChange, Int)] = []
        for c in changes {
            let k = "\(c.type.rawValue)|\(c.id)"
            let prev: Int?
            if let v = versions[k] { prev = v } else { prev = await store.version(of: c.type, id: c.id) }
            let version = max(nowMs, (prev ?? -1) + 1)
            versions[k] = version
            let env = Envelope(type: c.type, op: c.op, id: c.id, version: version,
                               updatedAt: Int(clock().timeIntervalSince1970), data: c.op == .delete ? nil : c.data)
            sealed.append(try RecordCrypto.seal(env.encoded(), key: key, deviceID: deviceID, recordID: Self.newRecordID()))
            applied.append((c, version))
        }
        try await relay.push(sealed)
        for (c, v) in applied { await store.setVersion(v, of: c.type, id: c.id) }
        await store.removePending(count: changes.count)
        report.pushed += changes.count
    }

    /// 128 random bits, URL-safe, within the relay's `[A-Za-z0-9_-]{8,64}` rule.
    static func newRecordID() -> String {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public actor InMemoryStateStore: SyncStateStore {
    var cur = 0
    var versions: [String: Int] = [:]
    var queue: [LocalChange] = []
    public init() {}
    public func cursor() -> Int { cur }
    public func setCursor(_ v: Int) { cur = v }
    public func version(of type: EnvelopeType, id: String) -> Int? { versions["\(type.rawValue)|\(id)"] }
    public func setVersion(_ v: Int, of type: EnvelopeType, id: String) { versions["\(type.rawValue)|\(id)"] = v }
    public func pending() -> [LocalChange] { queue }
    public func removePending(count: Int) { queue.removeFirst(min(count, queue.count)) }
    public func enqueue(_ c: LocalChange) { queue.append(c) }
}
