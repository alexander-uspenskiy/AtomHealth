import Foundation

/// Key/value storage for HealthKit query anchors and change fingerprints.
public protocol BlobStore: Sendable {
    func blob(_ key: String) async -> Data?
    func setBlob(_ data: Data?, for key: String) async
}

/// Durable `SyncStateStore` kept in one JSON file, written atomically and excluded from backups' plaintext exposure
/// by iOS file protection (set by the app on the containing directory). Holds no secrets: keys live in the Keychain.
public actor JSONFileStateStore: SyncStateStore, BlobStore {
    struct State: Codable {
        var cursor = 0
        var versions: [String: Int] = [:]
        var queue: [LocalChange] = []
        var blobs: [String: Data] = [:]
    }
    let url: URL
    var state: State

    public init(url: URL) {
        self.url = url
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(State.self, from: d) { state = s } else { state = State() }
    }

    func save() {
        guard let d = try? JSONEncoder().encode(state) else { return }
        try? d.write(to: url, options: [.atomic, .completeFileProtection])
    }
    static func key(_ t: EnvelopeType, _ id: String) -> String { "\(t.rawValue)|\(id)" }

    public func cursor() -> Int { state.cursor }
    public func setCursor(_ v: Int) { state.cursor = v; save() }
    public func version(of type: EnvelopeType, id: String) -> Int? { state.versions[Self.key(type, id)] }
    public func setVersion(_ v: Int, of type: EnvelopeType, id: String) { state.versions[Self.key(type, id)] = v; save() }
    public func pending() -> [LocalChange] { state.queue }
    public func removePending(count: Int) { state.queue.removeFirst(min(count, state.queue.count)); save() }
    /// Only the latest change per entity matters; an older queued change for the same entity is replaced.
    public func enqueue(_ c: LocalChange) {
        state.queue.removeAll { $0.type == c.type && $0.id == c.id }
        state.queue.append(c); save()
    }
    /// Several changes with one disk write (a photo is many chunks).
    public func enqueue(contentsOf changes: [LocalChange]) {
        for c in changes { state.queue.removeAll { $0.type == c.type && $0.id == c.id } }
        state.queue.append(contentsOf: changes); save()
    }
    public func blob(_ key: String) -> Data? { state.blobs[key] }
    public func setBlob(_ data: Data?, for key: String) { state.blobs[key] = data; save() }
}
