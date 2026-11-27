import Foundation

/// The Overview's Apple Health side: activity rings, the key indicators (resting heart rate, HRV, sleep, energy balance…),
/// range gauges and the trend chart series. Pure, like `DashboardMath`, which it borrows the Mac's meals and plan from.
public struct HealthMath: Sendable {
    public typealias Zone = DashboardSnapshot.Zone
    public let h: HealthSummary
    public let s: DashboardSnapshot?
    public let now: Date
    public let calendar: Calendar

    public enum Goal {
        public static let steps = 10_000.0, activeKcal = 500.0, exerciseMin = 30.0, sleepH = 8.0
    }

    public init(_ h: HealthSummary, dashboard: DashboardSnapshot? = nil, now: Date = Date(), calendar: Calendar = .current) {
        self.h = h; self.s = dashboard; self.now = now; self.calendar = calendar
    }

    public var todayKey: String { HealthMapping.dayKey(now, calendar: calendar) }
    public var today: HealthSummary.Day? { h.days.first { $0.day == todayKey } }
    /// Days before today, newest last (today is still being filled in, so averages leave it out).
    var past: [HealthSummary.Day] { h.days.filter { $0.day < todayKey } }
    func last7(_ f: (HealthSummary.Day) -> Double?) -> [Double] { past.suffix(7).compactMap(f) }
    func avg(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
    func series(_ f: (HealthSummary.Day) -> Double?) -> [Double] { h.days.suffix(14).compactMap(f) }

    // MARK: today's rings
    public struct Ring: Identifiable, Sendable {
        public var id: String
        public var title: String, unit: String
        public var value: Double, goal: Double
        public var progress: Double { goal > 0 ? value / goal : 0 }        // may pass 1: the goal is beaten
    }

    public func rings() -> [Ring] {
        let t = today
        return [Ring(id: "steps", title: "Steps", unit: "", value: t?.steps ?? 0, goal: Goal.steps),
                Ring(id: "active", title: "Active energy", unit: "kcal", value: t?.activeKcal ?? 0, goal: Goal.activeKcal),
                Ring(id: "exercise", title: "Exercise", unit: "min", value: t?.exerciseMin ?? 0, goal: Goal.exerciseMin)]
    }

    // MARK: key indicators
    public struct Index: Identifiable, Sendable {
        public var id: String
        public var title: String, value: String, unit: String, detail: String, word: String
        public var state: DashboardMath.NState
        public var spark: [Double]
    }

    /// Eight numbers worth a glance, most critical first. Anything Health has no data for is left out.
    public func indices() -> [Index] {
        var out: [Index] = []
        if let t = balanceToday() { out.append(t) }
        if let b = balanceWeek() { out.append(b) }
        if let r = restingHR() { out.append(r) }
        if let v = hrv() { out.append(v) }
        if let sl = sleep() { out.append(sl) }
        if let st = stepsWeek() { out.append(st) }
        if let v = h.vo2max {
            out.append(Index(id: "vo2", title: "VO₂ max", value: Fmt.num(v, 1), unit: "mL/kg/min", detail: "cardio fitness (Apple Watch)",
                             word: "latest", state: .ok, spark: []))
        }
        if let w = workoutsWeek() { out.append(w) }
        return out
    }

    func delta(_ v: Double, _ base: Double?, _ dp: Int, _ unit: String, _ what: String) -> String {
        base.map { "\(Fmt.signed(v - $0, dp)) \(unit) vs \(what)" } ?? "no \(what) yet"
    }

    func restingHR() -> Index? {
        guard let cur = h.days.last(where: { $0.restingHR != nil })?.restingHR else { return nil }
        let base = avg(last7 { $0.restingHR })
        let d = base.map { cur - $0 } ?? 0
        let st: DashboardMath.NState = d <= 3 ? .ok : d <= 6 ? .warn : .over
        return Index(id: "rhr", title: "Resting heart rate", value: Fmt.num(cur, 0), unit: "bpm",
                     detail: delta(cur, base, 0, "bpm", "7-day avg"),
                     word: st == .ok ? (d < -2 ? "well recovered" : "steady") : st == .warn ? "a little high" : "elevated", state: st,
                     spark: series { $0.restingHR })
    }

    func hrv() -> Index? {
        guard let cur = h.days.last(where: { $0.hrv != nil })?.hrv else { return nil }
        let base = avg(last7 { $0.hrv })
        let ratio = base.map { $0 > 0 ? cur / $0 : 1 } ?? 1
        let st: DashboardMath.NState = ratio >= 0.95 ? .ok : ratio >= 0.8 ? .warn : .over
        return Index(id: "hrv", title: "Heart rate variability", value: Fmt.num(cur, 0), unit: "ms",
                     detail: delta(cur, base, 0, "ms", "7-day baseline"),
                     word: ratio >= 1.05 ? "above baseline" : st == .ok ? "at baseline" : st == .warn ? "below baseline" : "low: go easy", state: st,
                     spark: series { $0.hrv })
    }

    func sleep() -> Index? {
        guard let cur = today?.sleepH ?? h.days.last(where: { $0.sleepH != nil })?.sleepH else { return nil }
        let base = avg(last7 { $0.sleepH })
        let st: DashboardMath.NState = cur >= 7 && cur <= 9.5 ? .ok : cur >= 6 ? .warn : .over
        return Index(id: "sleep", title: "Sleep last night", value: Fmt.num(cur, 1), unit: "h",
                     detail: delta(cur, base, 1, "h", "7-day avg"),
                     word: st == .ok ? "enough" : st == .warn ? "a bit short" : "too short", state: st, spark: series { $0.sleepH })
    }

    func stepsWeek() -> Index? {
        guard let a = avg(last7 { $0.steps }) else { return nil }
        let st: DashboardMath.NState = a >= 8_000 ? .ok : a >= 5_000 ? .warn : .over
        return Index(id: "steps7", title: "Steps, 7-day average", value: Fmt.thousands(a), unit: "/day",
                     detail: "goal \(Fmt.thousands(Goal.steps)) a day",
                     word: st == .ok ? "active" : st == .warn ? "moderate" : "low", state: st, spark: series { $0.steps })
    }

    func workoutsWeek() -> Index? {
        let since = now.addingTimeInterval(-7 * 86_400)
        let w = h.workouts.filter { $0.date >= since }
        let mins = w.reduce(0) { $0 + $1.minutes }
        let st: DashboardMath.NState = mins >= 150 ? .ok : mins >= 60 ? .warn : .over
        return Index(id: "workouts", title: "Workouts, last 7 days", value: "\(w.count)", unit: w.count == 1 ? "session" : "sessions",
                     detail: "\(Int(mins.rounded())) min · goal 150 min", word: st == .ok ? "goal met" : st == .warn ? "building up" : "little exercise",
                     state: st, spark: [])
    }

    // MARK: energy balance (food from the Mac, burn from Health)
    /// Calories eaten that day, from the meals the Mac confirmed; nil when nothing was logged.
    func intake(day key: String) -> Double? {
        guard let s else { return nil }
        let meals = s.meals.filter { $0.status == "confirmed" && HealthMapping.dayKey($0.date, calendar: calendar) == key }
        return meals.isEmpty ? nil : meals.reduce(0) { $0 + ($1.kcal ?? 0) }
    }

    func burn(_ d: HealthSummary.Day) -> Double? {
        guard let b = d.basalKcal, b > 0 else { return nil }
        return b + (d.activeKcal ?? 0)
    }

    /// Plan adjustment from the Mac (negative = a deficit is planned), when it has a plan.
    var plannedAdjust: Double? { s?.nutrition?.adjust }

    func balanceState(_ b: Double) -> (DashboardMath.NState, String) {
        let word = abs(b) < 100 ? "balanced" : b < 0 ? "deficit" : "surplus"
        guard let plan = plannedAdjust else { return (.ok, word) }
        let off = abs(b - plan)
        return (off <= 250 ? .ok : off <= 500 ? .warn : .over, word)
    }

    func balanceToday() -> Index? {
        guard let t = today, let out = burn(t), let eaten = intake(day: todayKey) else { return nil }
        let b = eaten - out
        let (st, word) = balanceState(b)
        return Index(id: "balance-today", title: "Energy balance today", value: Fmt.signed(b, 0), unit: "kcal",
                     detail: "\(Fmt.thousands(eaten)) in · \(Fmt.thousands(out)) out so far", word: word, state: st, spark: [])
    }

    /// Average of the complete days that have both food and burn data; ≈ 7,700 kcal per kg of body weight.
    public func balanceWeekValue() -> (kcal: Double, days: Int)? {
        let days = past.suffix(7).compactMap { d -> Double? in
            guard let out = burn(d), let eaten = intake(day: d.day) else { return nil }
            return eaten - out
        }
        guard let a = avg(days) else { return nil }
        return (a, days.count)
    }

    func balanceWeek() -> Index? {
        guard let (a, n) = balanceWeekValue() else { return nil }
        let (st, word) = balanceState(a)
        let kgWeek = a * 7 / 7_700
        return Index(id: "balance-week", title: "Energy balance, 7-day avg", value: Fmt.signed(a, 0), unit: "kcal/day",
                     detail: "≈ \(Fmt.signed(kgWeek, 2)) kg/week · \(n) logged day\(n == 1 ? "" : "s")", word: word, state: st, spark: [])
    }

    // MARK: range gauges
    public func gauges() -> [DashboardMath.Gauge] {
        var out: [DashboardMath.Gauge] = []
        if let cur = h.days.last(where: { $0.restingHR != nil })?.restingHR {
            let zones = [Zone(label: "Athletic", from: 38, to: 50, cls: "z1"), Zone(label: "Excellent", from: 50, to: 60, cls: "z2"),
                         Zone(label: "Good", from: 60, to: 70, cls: "z3"), Zone(label: "Average", from: 70, to: 80, cls: "z4"),
                         Zone(label: "High", from: 80, to: 90, cls: "z5"), Zone(label: "Very high", from: 90, to: 110, cls: "z6")]
            let a = avg(last7 { $0.restingHR })
            out.append(DashboardMath.Gauge(name: "Resting heart rate", unit: "bpm", value: cur, decimals: 0, min: 38, max: 110, zones: zones, refs: [],
                                           note: "Lower usually means better cardiovascular fitness; a jump of several beats above your own average can mean illness, stress or poor sleep.\(a.map { " Your 7-day average is \(Fmt.num($0, 0)) bpm." } ?? "")",
                                           target: nil, verdict: DashboardMath.zone(cur, in: zones)))
        }
        if let cur = today?.sleepH ?? h.days.last(where: { $0.sleepH != nil })?.sleepH {
            let zones = [Zone(label: "Very short", from: 3, to: 5, cls: "z6"), Zone(label: "Short", from: 5, to: 6, cls: "z5"),
                         Zone(label: "Fair", from: 6, to: 7, cls: "z4"), Zone(label: "Optimal", from: 7, to: 9, cls: "z2"),
                         Zone(label: "Long", from: 9, to: 12, cls: "z4")]
            let a = avg(last7 { $0.sleepH })
            out.append(DashboardMath.Gauge(name: "Sleep", unit: "h", value: cur, decimals: 1, min: 3, max: 12, zones: zones, refs: [(Goal.sleepH, "goal 8")],
                                           note: "Adults do best on 7–9 hours.\(a.map { " Your 7-day average is \(Fmt.num($0, 1)) h." } ?? "")",
                                           target: "\(Fmt.trim(Goal.sleepH)) h goal", verdict: DashboardMath.zone(cur, in: zones)))
        }
        return out
    }

    // MARK: HRV detail
    public struct HRVDetail: Sendable {
        public var points: [TrendPoint]          // daily average SDNN, oldest first
        public var rolling: [TrendPoint]         // trailing 7-reading average
        public var baseline7: Double?            // same 7-day baseline the Overview tile uses
        public var normalLow: Double?, normalHigh: Double?   // personal range: mean ± 0.75 SD over the period
        public var latest: Double?, min: Double?, max: Double?, average: Double?
        /// Latest as a share of the 7-day baseline (1.0 = at baseline).
        public var ratio: Double? {
            guard let l = latest, let b = baseline7, b > 0 else { return nil }
            return l / b
        }
    }

    public func hrvDetail(days: Int) -> HRVDetail {
        let pts = trend(.hrv, days: days).points
        let vals = pts.map(\.value)
        var rolling: [TrendPoint] = []
        for i in pts.indices where i >= 2 {
            let w = vals[Swift.max(0, i - 6)...i]
            rolling.append(TrendPoint(date: pts[i].date, value: w.reduce(0, +) / Double(w.count)))
        }
        let mean = avg(vals)
        var lo: Double?, hi: Double?
        if let mean, vals.count >= 5 {
            let sd = (vals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(vals.count - 1)).squareRoot()
            lo = mean - 0.75 * sd; hi = mean + 0.75 * sd
        }
        return HRVDetail(points: pts, rolling: rolling, baseline7: avg(last7 { $0.hrv }), normalLow: lo, normalHigh: hi,
                         latest: vals.last, min: vals.min(), max: vals.max(), average: mean)
    }

    // MARK: trend chart
    public enum Metric: String, CaseIterable, Identifiable, Sendable {
        case weight, fat, steps, active, exercise, sleep, restingHR, hrv
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .weight: "Weight"; case .fat: "Body fat"; case .steps: "Steps"; case .active: "Active kcal"
            case .exercise: "Exercise"; case .sleep: "Sleep"; case .restingHR: "Resting HR"; case .hrv: "HRV"
            }
        }
        public var unit: String {
            switch self {
            case .weight: "kg"; case .fat: "%"; case .steps: ""; case .active: "kcal"
            case .exercise: "min"; case .sleep: "h"; case .restingHR: "bpm"; case .hrv: "ms"
            }
        }
        public var decimals: Int { self == .weight ? 1 : self == .fat || self == .sleep ? 1 : 0 }
        /// Daily totals read better as bars, slow-moving measurements as a line.
        public var isBars: Bool { [.steps, .active, .exercise, .sleep].contains(self) }
    }

    public struct TrendPoint: Identifiable, Sendable {
        public var date: Date, value: Double
        public var id: Date { date }
    }

    public struct Trend: Sendable {
        public var metric: Metric
        public var points: [TrendPoint]
        public var goal: Double?
        public var goalLabel: String?
        public var average: Double?
        public var change: Double?
        public var latest: Double? { points.last?.value }
    }

    public func availableMetrics() -> [Metric] {
        Metric.allCases.filter { !trend($0, days: 30).points.isEmpty }
    }

    public func trend(_ m: Metric, days: Int) -> Trend {
        let since = calendar.startOfDay(for: now).addingTimeInterval(-Double(days - 1) * 86_400)
        var pts: [TrendPoint] = []
        var goal: Double?, label: String?
        switch m {
        case .weight, .fat:
            for r in s?.readings ?? [] where r.date >= since {
                if let v = m == .weight ? r.weight : r.fatPct { pts.append(TrendPoint(date: r.date, value: v)) }
            }
            if let s {
                let dm = DashboardMath(s, now: now, calendar: calendar)
                goal = m == .weight ? dm.targetWeight : dm.targetFat
                label = goal.map { "goal \(Fmt.trim($0))" }
            }
        default:
            for d in h.days {
                guard let date = Self.date(d.day, calendar), date >= since, let v = Self.value(m, d) else { continue }
                pts.append(TrendPoint(date: date, value: v))
            }
            switch m {
            case .steps: goal = Goal.steps; label = "goal \(Fmt.thousands(Goal.steps))"
            case .active: goal = Goal.activeKcal; label = "goal \(Int(Goal.activeKcal))"
            case .exercise: goal = Goal.exerciseMin; label = "goal \(Int(Goal.exerciseMin)) min"
            case .sleep: goal = Goal.sleepH; label = "goal \(Int(Goal.sleepH)) h"
            default: break
            }
        }
        // today's bar is still growing, so the average of daily totals leaves it out
        let complete = m.isBars ? pts.filter { HealthMapping.dayKey($0.date, calendar: calendar) < todayKey } : pts
        let a = complete.isEmpty ? nil : complete.map(\.value).reduce(0, +) / Double(complete.count)
        let change = !m.isBars && pts.count >= 2 ? pts.last!.value - pts.first!.value : nil
        return Trend(metric: m, points: pts, goal: goal, goalLabel: label, average: a, change: change)
    }

    static func value(_ m: Metric, _ d: HealthSummary.Day) -> Double? {
        switch m {
        case .steps: d.steps
        case .active: d.activeKcal
        case .exercise: d.exerciseMin
        case .sleep: d.sleepH
        case .restingHR: d.restingHR
        case .hrv: d.hrv
        case .weight, .fat: nil
        }
    }

    static func date(_ key: String, _ calendar: Calendar) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}
