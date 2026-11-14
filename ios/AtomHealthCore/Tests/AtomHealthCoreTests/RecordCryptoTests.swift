import Foundation
import Testing
@testable import AtomHealthCore

struct Vectors: Decodable {
    struct Case: Decodable { let device_id, record_id, nonce, ciphertext, plaintext: String }
    let key_b64: String
    let aad_prefix: String
    let cases: [Case]

    static func load() throws -> Vectors {
        let url = try #require(Bundle.module.url(forResource: "crypto_vectors", withExtension: "json", subdirectory: "Resources"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }
}

@Test func aadPrefixMatchesPython() throws {
    #expect(try Vectors.load().aad_prefix == RecordCrypto.aadPrefix)
}

@Test func decryptsPythonRecords() throws {
    let v = try Vectors.load()
    let key = try #require(Data(base64Encoded: v.key_b64))
    for c in v.cases {
        let pt = try RecordCrypto.open(nonce: c.nonce, ciphertext: c.ciphertext, key: key, deviceID: c.device_id, recordID: c.record_id)
        #expect(String(decoding: pt, as: UTF8.self) == c.plaintext)
    }
}

@Test func sealMatchesPythonBytesForFixedNonce() throws {
    let v = try Vectors.load()
    let key = try #require(Data(base64Encoded: v.key_b64))
    for c in v.cases {
        let nonce = try #require(Data(base64Encoded: c.nonce))
        let s = try RecordCrypto.seal(Data(c.plaintext.utf8), key: key, deviceID: c.device_id, recordID: c.record_id, nonce: nonce)
        #expect(s.ciphertext == c.ciphertext && s.nonce == c.nonce)
    }
}

@Test func rejectsTamperingRebindingAndWrongKey() throws {
    let v = try Vectors.load(), c = v.cases[0]
    let key = try #require(Data(base64Encoded: v.key_b64))
    func open(_ dev: String, _ rid: String, _ ct: String, key k: Data = key) throws -> Data {
        try RecordCrypto.open(nonce: c.nonce, ciphertext: ct, key: k, deviceID: dev, recordID: rid)
    }
    #expect(throws: CryptoError.authenticationFailed) { try open("dev-other", c.record_id, c.ciphertext) }
    #expect(throws: CryptoError.authenticationFailed) { try open(c.device_id, "rec-other-1", c.ciphertext) }
    var bytes = try #require(Data(base64Encoded: c.ciphertext)); bytes[0] ^= 1
    #expect(throws: CryptoError.authenticationFailed) { try open(c.device_id, c.record_id, bytes.base64EncodedString()) }
    #expect(throws: CryptoError.authenticationFailed) { try open(c.device_id, c.record_id, c.ciphertext, key: Data(count: 32)) }
    #expect(throws: CryptoError.badKey) { try open(c.device_id, c.record_id, c.ciphertext, key: Data(count: 5)) }
    #expect(throws: CryptoError.badEncoding) { try open(c.device_id, c.record_id, "AAAA") }
}

@Test func roundTripAndUniqueNonces() throws {
    let key = Data(count: 32)
    let a = try RecordCrypto.seal(Data("hi".utf8), key: key, deviceID: "d", recordID: "rec-00001")
    let b = try RecordCrypto.seal(Data("hi".utf8), key: key, deviceID: "d", recordID: "rec-00001")
    #expect(a.nonce != b.nonce)
    #expect(try RecordCrypto.open(nonce: a.nonce, ciphertext: a.ciphertext, key: key, deviceID: "d", recordID: "rec-00001") == Data("hi".utf8))
}
