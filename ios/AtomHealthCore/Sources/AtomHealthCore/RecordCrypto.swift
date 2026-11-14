import CryptoKit
import Foundation

public enum CryptoError: Error, Equatable {
    case badKey, badEncoding, authenticationFailed
}

/// End-to-end encryption of relay records. Wire format matches `src/atomhealth/relay.py`:
/// ChaCha20-Poly1305, 96-bit random nonce, ciphertext = encrypted bytes followed by the 16-byte tag,
/// AAD = "atomhealth-v1|" + device_id + "|" + record_id (so the relay cannot swap or re-attribute records).
public enum RecordCrypto {
    public static let aadPrefix = "atomhealth-v1|"
    static let tagLength = 16

    public struct Sealed: Equatable, Sendable {
        public let recordID: String
        public let nonce: String       // base64
        public let ciphertext: String  // base64
    }

    public static func aad(deviceID: String, recordID: String) -> Data {
        Data((aadPrefix + deviceID + "|" + recordID).utf8)
    }

    public static func seal(_ plaintext: Data, key: Data, deviceID: String, recordID: String,
                            nonce: Data? = nil) throws -> Sealed {
        let k = try symmetricKey(key)
        let n = try nonce.map { try ChaChaPoly.Nonce(data: $0) } ?? ChaChaPoly.Nonce()
        let box = try ChaChaPoly.seal(plaintext, using: k, nonce: n, authenticating: aad(deviceID: deviceID, recordID: recordID))
        return Sealed(recordID: recordID,
                      nonce: Data(n).base64EncodedString(),
                      ciphertext: (box.ciphertext + box.tag).base64EncodedString())
    }

    public static func open(nonce: String, ciphertext: String, key: Data, deviceID: String, recordID: String) throws -> Data {
        let k = try symmetricKey(key)
        guard let nd = decodeBase64(nonce), let cd = decodeBase64(ciphertext), cd.count >= tagLength else {
            throw CryptoError.badEncoding
        }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nd),
                                               ciphertext: cd.dropLast(tagLength), tag: cd.suffix(tagLength))
            return try ChaChaPoly.open(box, using: k, authenticating: aad(deviceID: deviceID, recordID: recordID))
        } catch is CryptoKitError {
            throw CryptoError.authenticationFailed
        }
    }

    static func symmetricKey(_ data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw CryptoError.badKey }
        return SymmetricKey(data: data)
    }

    /// Accepts standard and URL-safe base64, with or without padding (the Python side does the same).
    static func decodeBase64(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}
