import Foundation

/// What the phone itself reads from Apple Health for the Overview: one row per day for the last month plus the latest
/// VO₂ max and recent workouts. HealthKit-free (the reader lives in `AtomHealthKit`), so the maths on top is testable.
public struct HealthSummary: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        public var day: String                     // "yyyy-MM-dd", the calendar's time zone
        public var steps: Double?, activeKcal: Double?, basalKcal: Double?, exerciseMin: Double?
        public var restingHR: Double?, hrv: Double?, sleepH: Double?
        public init(day: String, steps: Double? = nil, activeKcal: Double? = nil, basalKcal: Double? = nil, exerciseMin: Double? = nil,
                    restingHR: Double? = nil, hrv: Double? = nil, sleepH: Double? = nil) {
            self.day = day; self.steps = steps; self.activeKcal = activeKcal; self.basalKcal = basalKcal
            self.exerciseMin = exerciseMin; self.restingHR = restingHR; self.hrv = hrv; self.sleepH = sleepH
        }
        var hasData: Bool { [steps, activeKcal, basalKcal, exerciseMin, restingHR, hrv, sleepH].contains { $0 != nil } }
    }

    public struct Workout: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var kind: String
        public var start: Double
        public var minutes: Double
        public var kcal: Double?, distanceKm: Double?
        public var date: Date { Date(timeIntervalSince1970: start) }
        public init(id: String, kind: String, start: Double, minutes: Double, kcal: Double? = nil, distanceKm: Double? = nil) {
            self.id = id; self.kind = kind; self.start = start; self.minutes = minutes; self.kcal = kcal; self.distanceKm = distanceKm
        }
    }

    public var generatedAt: Double
    public var days: [Day]                         // oldest first
    public var vo2max: Double?
    public var workouts: [Workout]                 // newest first
    public init(generatedAt: Double = Date().timeIntervalSince1970, days: [Day] = [], vo2max: Double? = nil, workouts: [Workout] = []) {
        self.generatedAt = generatedAt; self.days = days; self.vo2max = vo2max; self.workouts = workouts
    }

    /// Nothing at all came back: Health access is off, or the phone is locked and Health is unreadable right now.
    public var isEmpty: Bool { !days.contains { $0.hasData } && vo2max == nil && workouts.isEmpty }
}

public enum SleepMath {
    /// Apple Health often holds the same night from several sources (watch, phone, a sleep app), and a night is a run of
    /// stages with short wake-ups in between. Overlaps are merged so nothing counts twice, blocks less than 2 h apart form
    /// one night, and a night is credited to the day it ends on.
    public static func hoursByDay(_ intervals: [(start: Date, end: Date)], calendar: Calendar = .current) -> [String: Double] {
        let sorted = intervals.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [(start: Date, end: Date)] = []
        for i in sorted {
            if let last = merged.last, i.start <= last.end { merged[merged.count - 1].end = max(last.end, i.end) } else { merged.append(i) }
        }
        var out: [String: Double] = [:]
        var group: [(start: Date, end: Date)] = []
        func flush() {
            guard let end = group.last?.end else { return }
            out[HealthMapping.dayKey(end, calendar: calendar), default: 0] += group.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 3600
            group = []
        }
        for b in merged {
            if let last = group.last, b.start.timeIntervalSince(last.end) >= 2 * 3600 { flush() }
            group.append(b)
        }
        flush()
        return out
    }
}
