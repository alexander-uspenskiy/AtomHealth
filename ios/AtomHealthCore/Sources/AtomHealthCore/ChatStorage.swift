import Foundation

/// How much room the chat takes on the phone and when it will be too much. Pure, so it is unit-tested.
/// Photos dominate (a resized meal photo is up to ~300 KB, text is ~1 KB), so growth is measured from what was
/// really added over the last two weeks, not from a guess.
public struct ChatStorageReport: Equatable, Sendable {
    public enum Advice: Equatable, Sendable { case none, soon, full }

    /// The most the chat should take before the app suggests deleting old messages.
    public static let budgetBytes = 150_000_000
    /// Below this the chat is too small to be worth a warning, whatever the growth rate says.
    public static let quietBelowBytes = 10_000_000
    public static let forecastWindowDays = 14.0
    public static let warnDaysLeft = 60

    public var messages: Int
    public var usedBytes: Int
    public var recentBytes: Int          // added in the last `forecastWindowDays`
    public var oldest: Date?
    public var now: Date

    public init(messages: Int, usedBytes: Int, recentBytes: Int, oldest: Date?, now: Date = Date()) {
        self.messages = messages; self.usedBytes = usedBytes; self.recentBytes = recentBytes
        self.oldest = oldest; self.now = now
    }

    public var fraction: Double { Double(usedBytes) / Double(Self.budgetBytes) }

    /// Days the recent growth was measured over: the chat's age, between 1 and 14 days.
    var span: Double {
        let age = oldest.map { now.timeIntervalSince($0) / 86_400 } ?? 1
        return min(Self.forecastWindowDays, max(1, age))
    }
    public var bytesPerDay: Double { Double(recentBytes) / span }

    /// Whole days until the budget is used up at the recent pace; nil while the chat is not growing.
    public var daysLeft: Int? {
        guard bytesPerDay > 0 else { return nil }
        return max(0, Int((Double(Self.budgetBytes - usedBytes) / bytesPerDay).rounded(.down)))
    }

    public var advice: Advice {
        if usedBytes >= Self.budgetBytes { return .full }
        guard usedBytes >= Self.quietBelowBytes else { return .none }
        if fraction >= 0.8 || (daysLeft ?? .max) <= Self.warnDaysLeft { return .soon }
        return .none
    }

    public static func size(_ bytes: Int) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: Int64(bytes))
    }

    /// One plain sentence for the banner and the storage sheet.
    public var summary: String {
        var s = "Chat uses \(Self.size(usedBytes)) (\(messages) messages)"
        if let d = daysLeft, bytesPerDay >= 1_000 {
            s += d == 0 ? ", at the limit" : ", growing \(Self.size(Int(bytesPerDay)))/day: the \(Self.size(Self.budgetBytes)) limit in ~\(d) day\(d == 1 ? "" : "s")"
        }
        return s + "."
    }
}

/// What deleting everything older than `days` would remove.
public struct ChatCleanupOffer: Equatable, Sendable {
    public var days: Int
    public var messages: Int
    public var bytes: Int
    public init(days: Int, messages: Int, bytes: Int) { self.days = days; self.messages = messages; self.bytes = bytes }
}
