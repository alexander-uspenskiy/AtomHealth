import Foundation

/// Keeps the Mac's latest dashboard snapshot on the phone (one file, complete file protection), so the app opens
/// instantly and works offline. The raw JSON is stored as received; it is decoded with `DashboardSnapshot.decode(json:)`.
public actor DashboardStore {
    let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> DashboardSnapshot? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? DashboardSnapshot.decode(json: d)
    }

    /// An envelope that does not look like a snapshot is ignored rather than thrown: a bad record must never
    /// stall the sync cursor.
    public func apply(_ env: Envelope) {
        guard env.type == .dashboard else { return }
        if env.op == .delete { try? FileManager.default.removeItem(at: url); return }
        guard let data = env.data, let raw = try? JSONEncoder().encode(data),
              (try? DashboardSnapshot.decode(json: raw)) != nil else { return }
        try? raw.write(to: url, options: [.atomic, .completeFileProtection])
    }

    public func clear() { try? FileManager.default.removeItem(at: url) }
}

/// Sends dashboard envelopes to the `DashboardStore` and everything else (weights, meals) to Apple Health.
public struct RoutingSink: InboundSink {
    let health: InboundSink
    let dashboard: DashboardStore
    public init(health: InboundSink, dashboard: DashboardStore) { self.health = health; self.dashboard = dashboard }
    public func apply(_ env: Envelope) async throws {
        if env.type == .dashboard { await dashboard.apply(env) } else { try await health.apply(env) }
    }
}
