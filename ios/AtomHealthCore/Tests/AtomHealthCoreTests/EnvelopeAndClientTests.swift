import Foundation
import Testing
@testable import AtomHealthCore

final class MockTransport: HTTPTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    var reply: (Data, Int) = (Data("{}".utf8), 200)
    func send(_ request: URLRequest) async throws -> (Data, Int) { requests.append(request); return reply }
}

@Test func envelopeDecodesPythonPlaintext() throws {
    let v = try Vectors.load()
    for c in v.cases {
        let e = try Envelope.decode(Data(c.plaintext.utf8))
        #expect(e.v == 1 && !e.id.isEmpty)
    }
    let e = try Envelope.decode(Data(try Vectors.load().cases[0].plaintext.utf8))
    #expect(e.type == .weight && e.version == 3 && e.data?["weight_kg"]?.doubleValue == 78.4)
}

@Test func envelopeRoundTripsAndRejectsBad() throws {
    let e = Envelope(type: .activityDay, op: .upsert, id: "day:2026-11-13", version: 5, updatedAt: 10,
                     data: .object(["day": .string("2026-11-13"), "steps": .number(8000)]))
    #expect(try Envelope.decode(e.encoded()) == e)
    #expect(throws: (any Error).self) { try Envelope.decode(Data(#"{"v":2,"type":"weight","op":"upsert","id":"a","version":1,"updated_at":0,"data":{}}"#.utf8)) }
    #expect(throws: (any Error).self) { try Envelope.decode(Data(#"{"v":1,"type":"weight","op":"upsert","id":"a","version":1,"updated_at":0}"#.utf8)) }
}

@Test func clientEnforcesHttps() throws {
    _ = try RelayClient(url: "https://x.workers.dev/", token: nil)
    _ = try RelayClient(url: "http://localhost:8799", token: nil)
    for bad in ["http://example.com", "ftp://x", "https://", "nonsense"] {
        #expect(throws: RelayError.self) { try RelayClient(url: bad, token: nil) }
    }
}

@Test func pushBatchesAndAuthenticates() async throws {
    let t = MockTransport()
    let c = try RelayClient(url: "https://r.example", token: "dev.secret", transport: t)
    let recs = (0..<120).map { RecordCrypto.Sealed(recordID: "rec-\(String(format: "%05d", $0))", nonce: "AAAA", ciphertext: "AAAA") }
    try await c.push(recs)
    #expect(t.requests.count == 3)   // 50 + 50 + 20
    #expect(t.requests[0].value(forHTTPHeaderField: "authorization") == "Bearer dev.secret")
    #expect(t.requests[0].url?.path == "/v1/push")
}

@Test func pullParsesAndErrorsDoNotLeakToken() async throws {
    let t = MockTransport()
    let c = try RelayClient(url: "https://r.example", token: "dev.TOPSECRET", transport: t)
    t.reply = (Data(#"{"records":[{"record_id":"r1","device_id":"d","nonce":"n","ciphertext":"c"}],"next_seq":7,"has_more":false}"#.utf8), 200)
    let p = try await c.pull(since: 3, limit: 10)
    #expect(p.next_seq == 7 && p.records.count == 1)
    #expect(t.requests[0].url?.absoluteString == "https://r.example/v1/pull?since=3&limit=10")
    t.reply = (Data(#"{"error":"invalid token"}"#.utf8), 401)
    do { _ = try await c.pull(since: 0); Issue.record("expected throw") }
    catch let e as RelayError { #expect(e.status == 401 && !e.message.contains("TOPSECRET")) }
}
