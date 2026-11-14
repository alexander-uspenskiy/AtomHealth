import Foundation
import Testing
@testable import AtomHealthCore

actor FakeRelay: RelayAPI {
    struct Row { var seq: Int; var device: String; var rec: RecordCrypto.Sealed }
    var rows: [Row] = []
    var acks: [Int] = []
    var failPush = false
    let selfDevice: String
    init(device: String) { selfDevice = device }

    func push(_ records: [RecordCrypto.Sealed]) throws {
        if failPush { throw RelayError(message: "boom", status: 500) }
        for r in records { rows.append(Row(seq: rows.count + 1, device: selfDevice, rec: r)) }
    }
    func pull(since: Int, limit: Int) -> PullResult {
        let page = rows.filter { $0.seq > since }.prefix(limit)
        let mine = page.filter { $0.device != selfDevice }.map {
            PulledRecord(record_id: $0.rec.recordID, device_id: $0.device, nonce: $0.rec.nonce, ciphertext: $0.rec.ciphertext) }
        let next = page.last?.seq ?? since
        return PullResult(records: Array(mine), next_seq: next, has_more: next < rows.count)
    }
    func ack(cursor: Int) { acks.append(cursor) }
    func inject(device: String, id: String, env: Envelope, key: Data, asRecord: String? = nil) throws {
        var s = try RecordCrypto.seal(env.encoded(), key: key, deviceID: device, recordID: id)
        if let asRecord { s = RecordCrypto.Sealed(recordID: asRecord, nonce: s.nonce, ciphertext: s.ciphertext) }
        rows.append(Row(seq: rows.count + 1, device: device, rec: s))
    }
    func setFail(_ b: Bool) { failPush = b }
    var count: Int { rows.count }
}

actor RecordingSink: InboundSink {
    var applied: [Envelope] = []
    var fail = false
    func apply(_ env: Envelope) throws {
        if fail { throw RelayError(message: "healthkit denied", status: nil) }
        applied.append(env)
    }
    func setFail(_ b: Bool) { fail = b }
}

let K = Data(0..<32)

func weight(_ id: String, _ version: Int, _ kg: Double, op: Envelope.Op = .upsert) -> Envelope {
    Envelope(type: .weight, op: op, id: id, version: version, updatedAt: 0,
             data: op == .delete ? nil : .object(["weight_kg": .number(kg)]))
}

@Test func pushesLocalChangesEncryptedAndClearsOutbox() async throws {
    let relay = FakeRelay(device: "phone"), store = InMemoryStateStore(), sink = RecordingSink()
    await store.enqueue(LocalChange(type: .activityDay, id: "day:2026-11-13", op: .upsert,
                                    data: .object(["day": .string("2026-11-13"), "steps": .number(8000)])))
    let engine = SyncEngine(deviceID: "phone", key: K, relay: relay, store: store, sink: sink)
    let r = try await engine.cycle()
    #expect(r.pushed == 1 && r.pulled == 0)
    #expect(await store.pending().isEmpty)
    let row = await relay.rows[0]
    let pt = try RecordCrypto.open(nonce: row.rec.nonce, ciphertext: row.rec.ciphertext, key: K, deviceID: "phone", recordID: row.rec.recordID)
    let env = try Envelope.decode(pt)
    #expect(env.type == .activityDay && env.data?["steps"]?.doubleValue == 8000)
    #expect(!String(decoding: pt, as: UTF8.self).isEmpty && !row.rec.ciphertext.contains("steps"))
    #expect(row.rec.recordID.count >= 8)
}

@Test func appliesInboundNewerOnlyAndAdvancesCursor() async throws {
    let relay = FakeRelay(device: "phone"), store = InMemoryStateStore(), sink = RecordingSink()
    try await relay.inject(device: "mac", id: "rec-00000001", env: weight("w1", 100, 80), key: K)
    try await relay.inject(device: "mac", id: "rec-00000002", env: weight("w1", 100, 81), key: K)   // same version: stale
    try await relay.inject(device: "mac", id: "rec-00000003", env: weight("w1", 200, 79), key: K)
    let engine = SyncEngine(deviceID: "phone", key: K, relay: relay, store: store, sink: sink)
    let r = try await engine.cycle()
    #expect(r.pulled == 2 && r.stale == 1)
    #expect(await sink.applied.map { $0.data?["weight_kg"]?.doubleValue } == [80, 79])
    let cur = await store.cursor(), lastAck = await relay.acks.last
    #expect(cur == 3 && lastAck == 3)
    let again = try await engine.cycle()
    #expect(again == SyncReport())
}

@Test func deletesAreTombstonesAndOldUpsertsCannotResurrect() async throws {
    let relay = FakeRelay(device: "phone"), store = InMemoryStateStore(), sink = RecordingSink()
    try await relay.inject(device: "mac", id: "rec-00000001", env: weight("w1", 300, 0, op: .delete), key: K)
    try await relay.inject(device: "mac", id: "rec-00000002", env: weight("w1", 250, 80), key: K)
    let r = try await SyncEngine(deviceID: "phone", key: K, relay: relay, store: store, sink: sink).cycle()
    #expect(r.pulled == 1 && r.stale == 1)
    #expect(await sink.applied.first?.op == .delete)
}

@Test func forgedGarbageAndUnsupportedRecordsAreSkippedAndCounted() async throws {
    let relay = FakeRelay(device: "phone"), store = InMemoryStateStore(), sink = RecordingSink()
    try await relay.inject(device: "mac", id: "rec-00000001", env: weight("evil", 1, 99), key: K, asRecord: "rec-00000099") // re-bound
    try await relay.inject(device: "mac", id: "rec-00000002", env: Envelope(type: .workout, op: .upsert, id: "x", version: 1, updatedAt: 0, data: .object([:])), key: K) // not inbound for phone
    try await relay.inject(device: "mac", id: "rec-00000003", env: weight("ok", 5, 70), key: K)
    let r = try await SyncEngine(deviceID: "phone", key: K, relay: relay, store: store, sink: sink).cycle()
    #expect(r.bad == 2 && r.pulled == 1)
    #expect(await sink.applied.map(\.id) == ["ok"])
}

@Test func failedPushKeepsOutboxAndRetries() async throws {
    let relay = FakeRelay(device: "phone"), store = InMemoryStateStore(), sink = RecordingSink()
    await store.enqueue(LocalChange(type: .weight, id: "hk-1", op: .upsert, data: .object(["weight_kg": .number(77)])))
    let engine = SyncEngine(deviceID: "phone", key: K, relay: relay, store: store, sink: sink)
    await relay.setFail(true)
    await #expect(throws: RelayError.self) { try await engine.cycle() }
    let pend = await store.pending().count, held = await relay.count
    #expect(pend == 1 && held == 0)
    await relay.setFail(false)
    #expect(try await engine.cycle().pushed == 1)
    let pend2 = await store.pending().isEmpty, held2 = await relay.count
    #expect(pend2 && held2 == 1)
}

@Test func sinkFailureDoesNotAdvanceCursorAndRetriesLater() async throws {
    let relay = FakeRelay(device: "phone"), store = InMemoryStateStore(), sink = RecordingSink()
    try await relay.inject(device: "mac", id: "rec-00000001", env: weight("w1", 10, 80), key: K)
    let engine = SyncEngine(deviceID: "phone", key: K, relay: relay, store: store, sink: sink)
    await sink.setFail(true)
    await #expect(throws: RelayError.self) { try await engine.cycle() }
    let cur0 = await store.cursor(), v0 = await store.version(of: .weight, id: "w1")
    #expect(cur0 == 0 && v0 == nil)
    await sink.setFail(false)
    #expect(try await engine.cycle().pulled == 1)
}

@Test func versionsIncreasePerEntityAndExceedSeen() async throws {
    let relay = FakeRelay(device: "phone"), store = InMemoryStateStore(), sink = RecordingSink()
    let future = Int(Date().timeIntervalSince1970 * 1000) + 10_000_000
    await store.setVersion(future, of: .weight, id: "hk-1")
    await store.enqueue(LocalChange(type: .weight, id: "hk-1", op: .upsert, data: .object(["weight_kg": .number(1)])))
    await store.enqueue(LocalChange(type: .weight, id: "hk-1", op: .delete))
    _ = try await SyncEngine(deviceID: "phone", key: K, relay: relay, store: store, sink: sink).cycle()
    let vs = try await relay.rows.map { r in
        try Envelope.decode(RecordCrypto.open(nonce: r.rec.nonce, ciphertext: r.rec.ciphertext, key: K, deviceID: "phone", recordID: r.rec.recordID)).version }
    #expect(vs == [future + 1, future + 2])
}

@Test func twoEnginesExchangeThroughSharedRelay() async throws {
    // Phone pushes a weight; a Mac-like peer (different device id) pulls it. Models the full phone to Mac path.
    let relayPhone = FakeRelay(device: "phone")
    let sPhone = InMemoryStateStore()
    await sPhone.enqueue(LocalChange(type: .weight, id: "hk-9", op: .upsert, data: .object(["weight_kg": .number(78.4)])))
    _ = try await SyncEngine(deviceID: "phone", key: K, relay: relayPhone, store: sPhone, sink: RecordingSink()).cycle()
    // peer sees the same rows through its own identity
    let relayMac = FakeRelay(device: "mac")
    await relayMac.copyRows(from: relayPhone)
    let sink = RecordingSink()
    let r = try await SyncEngine(deviceID: "mac", key: K, relay: relayMac, store: InMemoryStateStore(), sink: sink).cycle()
    let got = await sink.applied.first?.data?["weight_kg"]?.doubleValue
    #expect(r.pulled == 1 && got == 78.4)
}

extension FakeRelay {
    func copyRows(from other: FakeRelay) async { rows = await other.rows }
}
