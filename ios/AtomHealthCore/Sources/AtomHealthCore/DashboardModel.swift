import Foundation

/// What the Mac sends in its `dashboard` envelope (`app.dashboard_snapshot()`): the numbers behind the Overview and
/// Trends tabs, already computed by the Mac so the phone never disagrees with it. Decoded leniently: every field the
/// UI can live without is optional, so a newer Mac adding fields (or an empty profile) never breaks the phone.
public struct DashboardSnapshot: Codable, Equatable, Sendable {
    public struct Profile: Codable, Equatable, Sendable {
        public var heightCm: Double?, age: Double?, sex: String?, targetWeight: Double?, targetFatPct: Double?, targetDate: String?
    }
    public struct Zone: Codable, Equatable, Sendable {
        public var label: String, from: Double, to: Double, cls: String
        public init(label: String, from: Double, to: Double, cls: String) { self.label = label; self.from = from; self.to = to; self.cls = cls }
    }
    public struct Optimal: Codable, Equatable, Sendable {
        public var weight: Double, fatPctRange: [Double], fatPct: Double
    }
    public struct Ref: Codable, Equatable, Sendable {
        public var bmiZones: [Zone], fatZones: [Zone], ffmiZones: [Zone], waterRange: [Double]
    }
    public struct Reading: Codable, Equatable, Sendable {
        public var ts: Double, weight: Double
        public var bmi: Double?, fatPct: Double?, fatKg: Double?, leanKg: Double?, muscleKg: Double?
        public var waterPct: Double?, tbwKg: Double?, ffmi: Double?, nffmi: Double?, fmi: Double?
        public var date: Date { Date(timeIntervalSince1970: ts) }
    }
    public struct Macro: Codable, Equatable, Sendable {
        public var key: String, label: String, g: Double, kcal: Double, pct: Double
    }
    public struct PlanMeal: Codable, Equatable, Sendable { public var label: String, kcal: Double, pct: Double }
    public struct Limits: Codable, Equatable, Sendable {
        public var fiberG: Double?, waterL: Double?, satFatG: Double?, sugarG: Double?, sodiumMg: Double?
    }
    public struct Nutrition: Codable, Equatable, Sendable {
        public var goal: String?, style: String?, kcal: Double?, weight: Double?, targetWeight: Double?
        public var bmr: Double?, maintenance: Double?, adjust: Double?, pace: Double?, weeks: Double?
        public var proteinPerKg: Double?, proteinBasisKg: Double?
        public var macros: [Macro]?, meals: [PlanMeal]?, limits: Limits?, warnings: [String]?
    }
    public struct Meal: Codable, Equatable, Sendable {
        public var ts: Double, type: String?, status: String?
        public var kcal: Double?, proteinG: Double?, carbsG: Double?, fatG: Double?, fiberG: Double?
        public var items: [String]?
        public var date: Date { Date(timeIntervalSince1970: ts) }
    }
    public struct AdviceItem: Codable, Equatable, Sendable {
        public var kind: String?, ts: Double?, headline: String?, text: String?, question: String?, usedLlm: Bool?
    }
    public struct Advice: Codable, Equatable, Sendable {
        public var today: [AdviceItem]?, week: AdviceItem?, removed: Double?
    }

    public var generatedAt: Double?
    public var profile: Profile
    public var healthyRange: [Double]?
    public var optimal: Optimal?
    public var ref: Ref?
    public var nutrition: Nutrition?
    public var first: Reading?
    public var readings: [Reading]
    public var meals: [Meal]
    public var advice: Advice?

    /// `Envelope.data` -> snapshot. Throws if it is not shaped like a snapshot (the envelope is then skipped).
    public static func decode(_ data: JSONValue) throws -> DashboardSnapshot {
        try decoder.decode(DashboardSnapshot.self, from: JSONEncoder().encode(data))
    }
    public static func decode(json: Data) throws -> DashboardSnapshot { try decoder.decode(DashboardSnapshot.self, from: json) }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }()
}
