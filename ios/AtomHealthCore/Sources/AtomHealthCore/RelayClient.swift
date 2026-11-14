import Foundation

public struct RelayError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public let status: Int?
    public var description: String { message }
}

public struct PulledRecord: Decodable, Equatable, Sendable {
    public let record_id: String
    public let device_id: String
    public let nonce: String
    public let ciphertext: String
}

public struct PullResult: Decodable, Equatable, Sendable {
    public let records: [PulledRecord]
    public let next_seq: Int
    public let has_more: Bool
}

/// Transport seam so the client can be tested without a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (d, r) = try await session.data(for: request)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public struct RelayClient: Sendable {
    public static let pushBatch = 50
    let base: URL
    let token: String?
    let transport: HTTPTransport

    /// HTTPS only, except loopback (same rule as `check_url` in relay.py).
    public init(url: String, token: String?, transport: HTTPTransport = URLSessionTransport()) throws {
        guard let u = URL(string: url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              let host = u.host, !host.isEmpty else { throw RelayError(message: "invalid relay url", status: nil) }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard u.scheme == "https" || (u.scheme == "http" && loopback) else {
            throw RelayError(message: "relay url must be https", status: nil)
        }
        self.base = u; self.token = token; self.transport = transport
    }

    func request(_ method: String, _ path: String, headers: [String: String] = [:], json: Any? = nil) async throws -> Data {
        guard let url = URL(string: base.absoluteString + path) else { throw RelayError(message: "bad path", status: nil) }
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.httpMethod = method
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let json {
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
            r.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        do {
            let (data, status) = try await transport.send(r)
            guard status < 400 else {
                // never echo the token; surface only the relay's own error string
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? ""
                throw RelayError(message: "relay answered \(status): \(msg)", status: status)
            }
            return data
        } catch let e as RelayError { throw e }
        catch { throw RelayError(message: "relay unreachable", status: nil) }
    }

    public func push(_ records: [RecordCrypto.Sealed]) async throws {
        for chunk in stride(from: 0, to: records.count, by: Self.pushBatch).map({ Array(records[$0..<min($0 + Self.pushBatch, records.count)]) }) {
            let body = chunk.map { ["record_id": $0.recordID, "nonce": $0.nonce, "ciphertext": $0.ciphertext] }
            _ = try await request("POST", "/v1/push", json: ["records": body])
        }
    }

    public func pull(since: Int, limit: Int = 100) async throws -> PullResult {
        let d = try await request("GET", "/v1/pull?since=\(since)&limit=\(limit)")
        return try JSONDecoder().decode(PullResult.self, from: d)
    }

    public func ack(cursor: Int) async throws {
        _ = try await request("POST", "/v1/ack", json: ["cursor": cursor])
    }
}
