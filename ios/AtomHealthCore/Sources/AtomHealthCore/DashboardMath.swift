import Foundation

/// The Overview tab's derived values: a port of the rules in the Mac dashboard (`static/index.html`: KPI cards,
/// range gauges, goal rows, today's nutrition). Pure and platform-free so it is unit-tested on macOS.
public struct DashboardMath: Sendable {
    public typealias Zone = DashboardSnapshot.Zone
    public typealias Reading = DashboardSnapshot.Reading

    public let s: DashboardSnapshot
    public let now: Date
    public let calendar: Calendar
    static let day = 86_400.0

    public init(_ s: DashboardSnapshot, now: Date = Date(), calendar: Calendar = .current) {
        self.s = s; self.now = now; self.calendar = calendar
    }

    // MARK: basics
    public var latest: Reading? { s.readings.last }
    var h: Double { (s.profile.heightCm ?? 0) / 100 }
    public var hasHeight: Bool { h > 0 }
    public func bmiKg(_ b: Double) -> Double { b * h * h }
    public var targetWeight: Double? { s.profile.targetWeight ?? s.optimal?.weight }
    public var targetFat: Double? { s.profile.targetFatPct ?? s.optimal?.fatPct }
    public var weightTargetIsDefault: Bool { s.profile.targetWeight == nil }
    public var fatTargetIsDefault: Bool { s.profile.targetFatPct == nil }

    /// The zone containing `v` (values past either end clamp to the first/last zone), as `zoneOf` in the web app.
    public static func zone(_ v: Double?, in zones: [Zone]?) -> Zone? {
        guard let v, let zones, let first = zones.first, let last = zones.last else { return nil }
        if let z = zones.first(where: { v >= $0.from && v < $0.to }) { return z }
        return v >= last.to ? last : first
    }

    // MARK: KPI tiles
    public struct KPI: Identifiable, Sendable {
        public var id: String
        public var label: String, unit: String
        public var decimals: Int
        public var value: Double?
        public var deltaSinceLast: Double?, deltaVsAverage: Double?, averageCount = 0
        public var goodDirection: Double            // +1 when up is good, -1 when down is good
        public var zone: Zone?
        public var targetText: String?, targetReached = false
        public var spark: [Double]
    }

    static let kpiSpec: [(key: String, label: String, unit: String, dp: Int, good: Double)] = [
        ("weight", "Weight", "kg", 2, -1), ("bmi", "BMI", "", 1, -1), ("fat_pct", "Body fat", "%", 1, -1),
        ("lean_kg", "Lean mass", "kg", 1, 1), ("muscle_kg", "Muscle (est.)", "kg", 1, 1), ("water_pct", "Body water", "%", 1, 1)]

    static func value(_ r: Reading, _ key: String) -> Double? {
        switch key {
        case "weight": r.weight
        case "bmi": r.bmi
        case "fat_pct": r.fatPct
        case "lean_kg": r.leanKg
        case "muscle_kg": r.muscleKg
        case "water_pct": r.waterPct
        case "tbw_kg": r.tbwKg
        case "ffmi": r.ffmi
        default: nil
        }
    }

    public func kpis() -> [KPI] {
        let R = s.readings
        guard let a = R.last else { return [] }
        let p = R.count > 1 ? R[R.count - 2] : nil
        return Self.kpiSpec.map { spec in
            let v = Self.value(a, spec.key)
            let d = p.flatMap { Self.value($0, spec.key) }.flatMap { prev in v.map { $0 - prev } }
            let prior = R.dropLast().filter { $0.ts >= a.ts - 7 * Self.day }.compactMap { Self.value($0, spec.key) }
            let da = v != nil && !prior.isEmpty ? v! - prior.reduce(0, +) / Double(prior.count) : nil
            var k = KPI(id: spec.key, label: spec.label, unit: spec.unit, decimals: spec.dp, value: v, deltaSinceLast: d,
                        deltaVsAverage: da, averageCount: prior.count, goodDirection: spec.good,
                        zone: kpiZone(spec.key, a), spark: R.suffix(24).compactMap { Self.value($0, spec.key) })
            let tg = spec.key == "weight" ? targetWeight : spec.key == "fat_pct" ? targetFat : nil
            if let tg, let v {
                let dd = v - tg
                k.targetReached = abs(dd) <= 0.5
                let isDefault = spec.key == "weight" ? weightTargetIsDefault : fatTargetIsDefault
                k.targetText = "\(Fmt.num(tg, 1))\(spec.key == "weight" ? " kg" : "%") \(isDefault ? "optimal" : "target") · "
                    + (k.targetReached ? "reached" : "\(Fmt.signed(-dd, 1)) to go")
            }
            return k
        }
    }

    func kpiZone(_ key: String, _ a: Reading) -> Zone? {
        guard let ref = s.ref, hasHeight else { return nil }
        switch key {
        case "weight", "bmi": return Self.zone(a.bmi, in: ref.bmiZones)
        case "fat_pct": return Self.zone(a.fatPct, in: ref.fatZones)
        case "lean_kg", "muscle_kg": return Self.zone(a.ffmi, in: ref.ffmiZones)
        case "water_pct":
            guard let w = a.waterPct, ref.waterRange.count == 2 else { return nil }
            return w < ref.waterRange[0] ? .init(label: "Low", from: 0, to: 0, cls: "z4")
                : w > ref.waterRange[1] ? .init(label: "High", from: 0, to: 0, cls: "z1") : .init(label: "Typical", from: 0, to: 0, cls: "z2")
        default: return nil
        }
    }

    // MARK: range gauges ("Where you stand")
    public struct Gauge: Identifiable, Sendable {
        public var id: String { name }
        public var name: String, unit: String
        public var value: Double
        public var decimals: Int
        public var min: Double, max: Double
        public var zones: [Zone]
        public var refs: [(value: Double, label: String)]
        public var note: String
        public var target: String?
        public var verdict: Zone?
    }

    public func weightGauge() -> Gauge? {
        guard let a = latest, hasHeight, let ref = s.ref, let opt = s.optimal, let hr = s.healthyRange, hr.count == 2 else { return nil }
        let zones = ref.bmiZones.map { Zone(label: $0.label, from: bmiKg($0.from), to: bmiKg($0.to), cls: $0.cls) }
        let toOpt = a.weight - opt.weight
        let note: String
        if a.weight > hr[1] { note = "\(Fmt.num(a.weight - hr[1], 1)) kg above the healthy upper limit (\(Fmt.trim(hr[1])) kg)." }
        else if a.weight < hr[0] { note = "\(Fmt.num(hr[0] - a.weight, 1)) kg below the healthy lower limit (\(Fmt.trim(hr[0])) kg)." }
        else {
            let rel = abs(toOpt) < 0.5 ? "You are at your optimal weight."
                : "\(Fmt.num(abs(toOpt), 1)) kg \(toOpt > 0 ? "above" : "below") your optimal weight of \(Fmt.trim(opt.weight)) kg."
            note = "Within your healthy range of \(Fmt.trim(hr[0]))–\(Fmt.trim(hr[1])) kg. \(rel)"
        }
        var refs: [(Double, String)] = [(opt.weight, "optimal \(Fmt.trim(opt.weight))")]
        if let t = s.profile.targetWeight, abs(t - opt.weight) > 1 { refs.append((t, "target \(Fmt.trim(t))")) }
        return Gauge(name: "Weight", unit: "kg", value: a.weight, decimals: 2, min: bmiKg(15), max: bmiKg(40), zones: zones, refs: refs,
                     note: note, target: targetWeight.map { "\(Fmt.trim($0)) kg \(weightTargetIsDefault ? "optimal" : "target")" },
                     verdict: Self.zone(a.weight, in: zones))
    }

    public func gauges() -> [Gauge] {
        guard let a = latest, hasHeight, let ref = s.ref, let opt = s.optimal else { return [] }
        var out: [Gauge] = []
        if let bmi = a.bmi, let lo = ref.bmiZones.first?.from, let hi = ref.bmiZones.last?.to {
            out.append(Gauge(name: "Body Mass Index", unit: "", value: bmi, decimals: 1, min: lo, max: hi, zones: ref.bmiZones,
                             refs: [(22, "optimal 22")],
                             note: "WHO classification. BMI ignores muscle mass, so read it together with body fat.",
                             target: "22 optimal", verdict: Self.zone(bmi, in: ref.bmiZones)))
        }
        if let f = a.fatPct, let lo = ref.fatZones.first?.from, let hi = ref.fatZones.last?.to, opt.fatPctRange.count == 2 {
            let fl = opt.fatPctRange[0], fh = opt.fatPctRange[1]
            let verdict: String
            if f > fh { verdict = "You are \(Fmt.num(f - fh, 1)) points above it, about \(Fmt.num((f - fh) / 100 * a.weight, 1)) kg of fat." }
            else if f < fl { verdict = "You are below it." } else { verdict = "You are within it." }
            out.append(Gauge(name: "Body fat (estimate)", unit: "%", value: f, decimals: 1, min: lo, max: hi, zones: ref.fatZones,
                             refs: [(opt.fatPct, "optimal \(Fmt.trim(opt.fatPct))")],
                             note: "Healthy range for your age and sex: \(Fmt.trim(fl))–\(Fmt.trim(fh))%. \(verdict)",
                             target: targetFat.map { "\(Fmt.trim($0))% \(fatTargetIsDefault ? "optimal" : "target")" },
                             verdict: Self.zone(f, in: ref.fatZones)))
        }
        if let w = a.waterPct, ref.waterRange.count == 2 {
            let wl = ref.waterRange[0], wh = ref.waterRange[1]
            let zones = [Zone(label: "Low", from: wl - 15, to: wl, cls: "z4"), Zone(label: "Typical", from: wl, to: wh, cls: "z2"),
                         Zone(label: "High", from: wh, to: wh + 10, cls: "z1")]
            out.append(Gauge(name: "Body water (estimate)", unit: "%", value: w, decimals: 1, min: wl - 15, max: wh + 10, zones: zones, refs: [],
                             note: "Typical total body water for your sex: \(Fmt.trim(wl))–\(Fmt.trim(wh))%. Roughly \(Fmt.num(a.tbwKg, 1)) kg of you is water.",
                             target: nil, verdict: Self.zone(w, in: zones)))
        }
        if let f = a.ffmi, let lo = ref.ffmiZones.first?.from, let hi = ref.ffmiZones.last?.to {
            out.append(Gauge(name: "Fat-free mass index (FFMI)", unit: "", value: f, decimals: 1, min: lo, max: hi, zones: ref.ffmiZones, refs: [],
                             note: "Lean mass ÷ height². Normalised for height: \(Fmt.num(a.nffmi, 1)). Fat mass index (FMI): \(Fmt.num(a.fmi, 1)) kg/m².",
                             target: nil, verdict: Self.zone(f, in: ref.ffmiZones)))
        }
        return out
    }

    // MARK: goals
    public enum GoalStatus: Sendable { case needData, onTrack, offTrack, reached
        public var label: String { switch self { case .needData: "Need data"; case .onTrack: "On track"; case .offTrack: "Off track"; case .reached: "Reached" } }
    }
    public struct GoalRow: Identifiable, Sendable {
        public var id: String { title }
        public var title: String
        public var isOptimal: Bool
        public var current: Double, target: Double, unit: String
        public var decimals: Int
        public var progress: Double                      // 0...1
        public var status: GoalStatus
        public var weeklyPace: Double?, eta: Date?, outlook: String, needPerWeek: Double?, targetDate: String?
        public var summary: String
    }

    /// Least-squares slope per day over the last `days` days, like `slope()` in the web app (needs 3 points over 2+ days).
    public func slope(_ key: String, days: Double) -> Double? {
        guard let end = s.readings.last?.ts else { return nil }
        let pts = s.readings.filter { $0.ts >= end - days * Self.day }.compactMap { r in Self.value(r, key).map { (r.ts / Self.day, $0) } }
        guard pts.count >= 3, let f = pts.first, let l = pts.last, (l.0 - f.0) >= 2 else { return nil }
        let mx = pts.map(\.0).reduce(0, +) / Double(pts.count), my = pts.map(\.1).reduce(0, +) / Double(pts.count)
        var n = 0.0, d = 0.0
        for (x, y) in pts { n += (x - mx) * (y - my); d += (x - mx) * (x - mx) }
        return d == 0 ? nil : n / d
    }

    public func goals() -> [GoalRow] {
        guard let a = latest else { return [] }
        var rows: [GoalRow] = []
        if let t = targetWeight {
            rows.append(goalRow(title: "Weight goal", isOptimal: weightTargetIsDefault, cur: a.weight, tgt: t,
                                start: s.first?.weight ?? s.readings[0].weight, unit: "kg", key: "weight"))
        }
        if let t = targetFat, let cur = a.fatPct {
            rows.append(goalRow(title: "Body fat goal", isOptimal: fatTargetIsDefault, cur: cur, tgt: t,
                                start: s.first?.fatPct ?? cur, unit: "%", key: "fat_pct"))
        }
        return rows
    }

    func goalRow(title: String, isOptimal: Bool, cur: Double, tgt: Double, start: Double, unit: String, key: String) -> GoalRow {
        let left = cur - tgt, sl = slope(key, days: 30) ?? slope(key, days: 90)
        let total = start - tgt
        let done = abs(total) < 1e-9 ? 1 : (start - cur) / total
        let p = Swift.max(0, Swift.min(1, done))
        var status = GoalStatus.needData, outlook = "Needs ~3 readings over 2+ days", eta: Date?
        if abs(left) < (key == "weight" ? 0.2 : 0.3) { status = .reached; outlook = "Target reached 🎯" }
        else if let sl, left * sl < 0 {
            let days = left / -sl
            eta = (s.readings.last?.date ?? now).addingTimeInterval(days * Self.day)
            status = .onTrack; outlook = "\(Int(days.rounded())) days at this pace"
        } else if sl != nil { status = .offTrack; outlook = "Trend is moving away from the target" }
        var need: Double?
        if let td = s.profile.targetDate, abs(left) > 0.2, let end = Self.isoDate(td), let last = s.readings.last {
            let wk = end.timeIntervalSince(last.date) / Self.day / 7
            if wk > 0 { need = -left / wk }
        }
        return GoalRow(title: title, isOptimal: isOptimal, current: cur, target: tgt, unit: unit, decimals: 1, progress: p, status: status,
                       weeklyPace: sl.map { $0 * 7 }, eta: eta, outlook: outlook, needPerWeek: need, targetDate: s.profile.targetDate,
                       summary: "\(Fmt.num(cur, 1)) → \(Fmt.num(tgt, 1)) \(unit) · \(Fmt.num(abs(left), 1)) \(unit) \(left > 0 ? "to lose" : "to gain") · \(Int((p * 100).rounded()))% done")
    }

    /// "For 187 cm: healthy 64.7–87.1 kg · optimal 76.9 kg (BMI 22) · body fat 11–21%"
    public func goalNote() -> String? {
        guard let hr = s.healthyRange, hr.count == 2, let o = s.optimal, o.fatPctRange.count == 2, let cm = s.profile.heightCm else { return nil }
        return "For \(Fmt.trim(cm)) cm: healthy \(Fmt.trim(hr[0]))–\(Fmt.trim(hr[1])) kg · optimal \(Fmt.trim(o.weight)) kg (BMI 22) · body fat \(Fmt.trim(o.fatPctRange[0]))–\(Fmt.trim(o.fatPctRange[1]))%"
    }

    static func isoDate(_ s: String) -> Date? {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; return f.date(from: s)
    }

    // MARK: today's nutrition
    public enum NState: Sendable { case low, ok, warn, over }

    /// `reach`: a goal to reach (protein, fibre); otherwise a limit to stay under (energy, carbs, fat).
    public static func nState(_ p: Double, reach: Bool) -> NState {
        if reach { return p >= 1 ? .ok : p >= 0.7 ? .warn : .low }
        return p > 1.15 ? .over : p > 1.05 ? .warn : p >= 0.85 ? .ok : .low
    }

    public struct Indicator: Identifiable, Sendable {
        public var id: String { name }
        public var name: String, unit: String
        public var value: Double, target: Double
        public var reach: Bool
        public var state: NState
        public var word: String, detail: String
        public var progress: Double { target > 0 ? Swift.min(value / target, 1) : 0 }
    }

    public var todayMeals: [DashboardSnapshot.Meal] {
        let start = calendar.startOfDay(for: now).timeIntervalSince1970
        return s.meals.filter { $0.ts >= start }.sorted { $0.ts < $1.ts }
    }
    public var todaySaved: [DashboardSnapshot.Meal] { todayMeals.filter { $0.status == "confirmed" } }
    func sum(_ meals: [DashboardSnapshot.Meal], _ f: (DashboardSnapshot.Meal) -> Double?) -> Double { meals.reduce(0) { $0 + (f($1) ?? 0) } }

    public func todayTotals() -> (kcal: Double, protein: Double, carbs: Double, fat: Double, fiber: Double) {
        let d = todaySaved
        return (sum(d, \.kcal), sum(d, \.proteinG), sum(d, \.carbsG), sum(d, \.fatG), sum(d, \.fiberG))
    }

    public func indicators() -> [Indicator] {
        guard let n = s.nutrition, let kcal = n.kcal, kcal > 0 else { return [] }
        let t = todayTotals()
        let mg = Dictionary(uniqueKeysWithValues: (n.macros ?? []).map { ($0.key, $0.g) })
        let rows: [(String, Double, Double?, Bool, String)] = [
            ("Energy", t.kcal, kcal, false, "kcal"), ("Protein", t.protein, mg["protein"], true, "g"),
            ("Carbs", t.carbs, mg["carbs"], false, "g"), ("Fat", t.fat, mg["fat"], false, "g"),
            ("Fibre", t.fiber, n.limits?.fiberG, true, "g")]
        return rows.compactMap { name, v, target, reach, unit in
            guard let target, target > 0 else { return nil }
            let st = Self.nState(v / target, reach: reach), left = target - v
            let say: [NState: String] = [.low: "room left", .ok: "on target", .warn: "near limit", .over: "over"]
            let word = reach ? (st == .ok ? "goal met" : st == .warn ? "almost there" : "keep going") : say[st]!
            let detail = left >= 0 ? "\(Int(left.rounded())) \(unit)\(reach ? " to go" : " left")"
                                   : "\(Int((-left).rounded())) \(unit)\(reach ? " above goal" : " over")"
            return Indicator(name: name, unit: unit, value: v, target: target, reach: reach, state: st, word: word, detail: detail)
        }
    }

    public struct Tile: Identifiable, Sendable {
        public var id: String { title }
        public var title: String, value: String, unit: String, detail: String, word: String
        public var state: NState
        public var split: [Double]?
    }

    /// Ratios that say more than raw totals: macro split, protein per kg, fibre density, 7-day average.
    public func indices() -> [Tile] {
        guard let n = s.nutrition, let kcal = n.kcal, kcal > 0 else { return [] }
        let t = todayTotals()
        var tiles: [Tile] = []
        let mk = 4 * t.protein + 4 * t.carbs + 9 * t.fat
        let plan = ["protein", "carbs", "fat"].map { k in (n.macros ?? []).first { $0.key == k }?.pct ?? 0 }
        if mk > 0 {
            let share = [4 * t.protein / mk, 4 * t.carbs / mk, 9 * t.fat / mk].map { ($0 * 100).rounded() }
            let dev = zip(share, plan).map { abs($0 - $1) }.max() ?? 0
            tiles.append(Tile(title: "Macro split", value: share.map { String(Int($0)) }.joined(separator: " / "), unit: "% P/C/F",
                              detail: "plan \(plan.map { String(Int($0)) }.joined(separator: " / ")) %",
                              word: dev <= 5 ? "balanced" : dev <= 10 ? "drifting" : "off plan",
                              state: dev <= 5 ? .ok : dev <= 10 ? .warn : .over, split: share))
        } else {
            tiles.append(Tile(title: "Macro split", value: "—", unit: "% P/C/F", detail: "plan \(plan.map { String(Int($0)) }.joined(separator: " / ")) %",
                              word: "no data", state: .low, split: nil))
        }
        if let perKg = n.proteinPerKg, let basis = n.proteinBasisKg, let w = n.weight, w > 0 {
            let kg = t.protein / w, st = Self.nState(perKg > 0 ? kg / perKg : 0, reach: true)
            tiles.append(Tile(title: "Protein per kg", value: Fmt.num(kg, 2), unit: "g/kg", detail: "target \(Fmt.trim(perKg)) g/kg of \(Fmt.trim(basis)) kg",
                              word: st == .ok ? "goal met" : st == .warn ? "almost there" : "keep going", state: st, split: nil))
        }
        let fd = t.kcal > 0 ? t.fiber / t.kcal * 1000 : 0, fs = t.kcal > 0 ? Self.nState(fd / 14, reach: true) : .low
        tiles.append(Tile(title: "Fibre density", value: Fmt.num(fd, 1), unit: "g/1000 kcal", detail: "target 14 g/1000 kcal",
                          word: t.kcal > 0 ? (fs == .ok ? "good" : fs == .warn ? "fair" : "low") : "no data", state: fs, split: nil))
        let since = now.timeIntervalSince1970 - 7 * Self.day
        var days: [Date: Double] = [:]
        for m in s.meals where m.status == "confirmed" && m.ts >= since { days[calendar.startOfDay(for: m.date), default: 0] += m.kcal ?? 0 }
        let avg = days.isEmpty ? 0 : days.values.reduce(0, +) / Double(days.count)
        let st = days.isEmpty ? NState.low : Self.nState(avg / kcal, reach: false)
        let words: [NState: String] = [.low: "under plan", .ok: "on target", .warn: "near limit", .over: "over"]
        tiles.append(Tile(title: "7-day average", value: String(Int(avg.rounded())), unit: "kcal/day",
                          detail: "\(days.count) logged day\(days.count == 1 ? "" : "s") · plan \(Int(kcal)) kcal",
                          word: days.isEmpty ? "no data" : words[st]!, state: st, split: nil))
        return tiles
    }

    /// "Today: 1,203 / 1,872 kcal · 669 left" and the macro line, calculated from saved meals (never from the model).
    public func coachCalculation() -> (headline: String, detail: String, mealCount: Int) {
        let t = todayTotals(), n = s.nutrition
        var head = "Today: \(Fmt.thousands(t.kcal))"
        if let k = n?.kcal, k > 0 {
            head += " / \(Fmt.thousands(k)) kcal"
            let left = (k - t.kcal).rounded()
            head += left >= 0 ? " · \(Fmt.thousands(left)) left" : " · \(Fmt.thousands(-left)) over"
        } else { head += " kcal" }
        let pT = (n?.macros ?? []).first { $0.key == "protein" }?.g
        let fT = n?.limits?.fiberG
        let detail = "Protein \(Int(t.protein.rounded()))\(pT.map { " / \(Int($0))" } ?? "") g · Carbs \(Int(t.carbs.rounded())) g · Fat \(Int(t.fat.rounded())) g · Fibre \(Int(t.fiber.rounded()))\(fT.map { " / \(Int($0))" } ?? "") g"
        return (head, detail, todaySaved.count)
    }
}

/// Number formatting shared by the dashboard (locale-independent so tests are stable).
public enum Fmt {
    public static func num(_ v: Double?, _ dp: Int = 1) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.\(dp)f", roundHalfUp(v, dp))
    }
    /// Like JavaScript's `toFixed`: halves round away from zero (printf rounds them to even: 83.25 -> "83.2").
    static func roundHalfUp(_ v: Double, _ dp: Int) -> Double {
        let f = pow(10, Double(dp)); return (v * f).rounded(.toNearestOrAwayFromZero) / f
    }
    /// 76.9 -> "76.9", 64.0 -> "64"
    public static func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", (v * 10).rounded() / 10)
    }
    public static func signed(_ v: Double, _ dp: Int = 1) -> String {
        (v > 0 ? "+" : v < 0 ? "−" : "") + String(format: "%.\(dp)f", roundHalfUp(abs(v), dp))
    }
    public static func thousands(_ v: Double) -> String {
        let n = Int(v.rounded()), s = String(abs(n))
        var out = "", c = 0
        for ch in s.reversed() { if c > 0 && c % 3 == 0 { out.append(",") }; out.append(ch); c += 1 }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }
}
