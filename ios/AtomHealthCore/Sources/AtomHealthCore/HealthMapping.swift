import Foundation

/// Pure (HealthKit-free) mapping between Health data and relay envelopes, so it is unit-testable on any platform.
/// Field names and ranges follow `sync.py` (`_upsert_weight`, `apply_envelope`).
public enum HealthMapping {
    static func object(_ pairs: [(String, Double?)], extra: [String: JSONValue] = [:]) -> JSONValue {
        var o = extra
        for (k, v) in pairs { if let v { o[k] = .number(v) } }
        return .object(o)
    }

    /// "yyyy-MM-dd" in the calendar's time zone: the day key shared with the Mac.
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func weightChange(uuid: String, date: Date, kg: Double, fatPct: Double? = nil, leanKg: Double? = nil) -> LocalChange {
        LocalChange(type: .weight, id: "hk:\(uuid)", op: .upsert,
                    data: object([("ts", date.timeIntervalSince1970.rounded()), ("weight_kg", kg), ("fat_pct", fatPct), ("lean_kg", leanKg)]))
    }

    public static func activityDayChange(day: String, activeKcal: Double?, basalKcal: Double?, steps: Double?) -> LocalChange {
        LocalChange(type: .activityDay, id: "day:\(day)", op: .upsert,
                    data: object([("active_kcal", activeKcal), ("basal_kcal", basalKcal), ("steps", steps.map { $0.rounded() })],
                                 extra: ["day": .string(day)]))
    }

    public static func nutritionDayChange(day: String, kcal: Double?, protein: Double?, carbs: Double?, fat: Double?, fiber: Double?) -> LocalChange {
        LocalChange(type: .nutritionDay, id: "day:\(day)", op: .upsert,
                    data: object([("kcal", kcal), ("protein_g", protein), ("carbs_g", carbs), ("fat_g", fat), ("fiber_g", fiber)],
                                 extra: ["day": .string(day)]))
    }

    public static func workoutChange(uuid: String, start: Date, end: Date?, type: String, kcal: Double?, distanceM: Double?) -> LocalChange {
        var extra: [String: JSONValue] = ["type": .string(type)]
        if let end { extra["end_ts"] = .number(end.timeIntervalSince1970.rounded()) }
        return LocalChange(type: .workout, id: "hk:\(uuid)", op: .upsert,
                           data: object([("start_ts", start.timeIntervalSince1970.rounded()), ("kcal", kcal), ("distance_m", distanceM)], extra: extra))
    }

    public static func deletion(type: EnvelopeType, id: String) -> LocalChange {
        LocalChange(type: type, id: id, op: .delete)
    }
}

/// A validated inbound change, ready to be written into Apple Health.
public enum HealthWrite: Equatable, Sendable {
    case weight(id: String, version: Int, date: Date, kg: Double, fatPct: Double?, leanKg: Double?)
    case meal(id: String, version: Int, date: Date, caption: String?, mealType: String?,
              kcal: Double, protein: Double?, carbs: Double?, fat: Double?, fiber: Double?)
    case remove(type: EnvelopeType, id: String, version: Int)

    public enum Invalid: Error, Equatable { case field(String), unsupported }

    public static func decode(_ env: Envelope, now: Date = Date()) throws -> HealthWrite {
        guard SyncEngine.inboundTypes.contains(env.type) else { throw Invalid.unsupported }
        if env.op == .delete { return .remove(type: env.type, id: env.id, version: env.version) }
        guard let d = env.data else { throw Invalid.field("data") }
        func num(_ k: String, _ lo: Double, _ hi: Double, required: Bool = true) throws -> Double? {
            guard let v = d[k], v != .null else { if required { throw Invalid.field(k) } else { return nil } }
            guard let n = v.doubleValue, n >= lo, n <= hi else { throw Invalid.field(k) }
            return n
        }
        let date = Date(timeIntervalSince1970: try num("ts", 946_684_800, now.timeIntervalSince1970 + 86_400)!)
        switch env.type {
        case .weight:
            return .weight(id: env.id, version: env.version, date: date, kg: try num("weight_kg", 20, 300)!,
                           fatPct: try num("fat_pct", 2, 75, required: false), leanKg: try num("lean_kg", 10, 200, required: false))
        case .meal:
            return .meal(id: env.id, version: env.version, date: date,
                         caption: d["caption"]?.stringValue.map { String($0.prefix(200)) },
                         mealType: d["meal_type"]?.stringValue.map { String($0.prefix(20)) },
                         kcal: try num("kcal", 0, 20_000)!, protein: try num("protein_g", 0, 5_000, required: false),
                         carbs: try num("carbs_g", 0, 5_000, required: false), fat: try num("fat_g", 0, 5_000, required: false),
                         fiber: try num("fiber_g", 0, 5_000, required: false))
        default: throw Invalid.unsupported
        }
    }
}
