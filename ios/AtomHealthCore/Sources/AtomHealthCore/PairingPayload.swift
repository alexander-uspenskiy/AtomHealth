import Foundation

/// One-time code created on the Mac (`python -m atomhealth.relay pair-phone`). Matches `pairing_code()` in relay.py.
public struct PairingPayload: Equatable, Sendable {
    public static let prefix = "ahpair1:"
    public enum Invalid: Error, Equatable { case format, version, url, token, key }

    public let url: String, deviceID: String, token: String
    public let key: Data

    struct Wire: Codable { let v: Int; let u: String; let d: String; let t: String; let k: String }

    public static func decode(_ text: String) throws -> PairingPayload {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix(prefix), let raw = RecordCrypto.decodeBase64(String(s.dropFirst(prefix.count))),
              let w = try? JSONDecoder().decode(Wire.self, from: raw) else { throw Invalid.format }
        guard w.v == 1 else { throw Invalid.version }
        guard (try? RelayClient(url: w.u, token: nil)) != nil else { throw Invalid.url }
        // token is "<device id>.<secret>" and must belong to the device id in the code
        guard w.t.hasPrefix(w.d + "."), w.t.count >= w.d.count + 1 + 6, !w.d.isEmpty else { throw Invalid.token }
        guard let key = RecordCrypto.decodeBase64(w.k), key.count == 32 else { throw Invalid.key }
        return PairingPayload(url: w.u.trimmingCharacters(in: CharacterSet(charactersIn: "/")), deviceID: w.d, token: w.t, key: key)
    }
}
