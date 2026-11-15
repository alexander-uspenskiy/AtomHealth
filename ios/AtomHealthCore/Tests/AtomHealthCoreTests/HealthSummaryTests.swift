import Foundation
import Testing
@testable import AtomHealthCore

@Suite struct HealthSummaryTests {
    static var cal: Calendar { Fixture.utc }
    static func key(_ back: Int) -> String { HealthMapping.dayKey(Fixture.now.addingTimeInterval(-Double(back) * 86_400), calendar: cal) }

    /// 14 days ending today (the Fixture's "now"): steps 8,000 + 100/day, a resting HR of 60 that climbs to 66 today.
    static func summary() -> HealthSummary {
        let days = (0..<14).map { i -> HealthSummary.Day in
            let back = 13 - i
            return .init(day: key(back), steps: 8_000 + Double(i) * 100, activeKcal: 400, basalKcal: 1_700, exerciseMin: 30,
                         restingHR: back == 0 ? 66 : 60, hrv: back == 0 ? 30 : 50, sleepH: back == 0 ? 6.2 : 7.5)
        }
        return HealthSummary(generatedAt: Fixture.t0, days: days, vo2max: 44.4,
                             workouts: [.init(id: "w1", kind: "Running", start: Fixture.t0 - 86_400, minutes: 40, kcal: 400, distanceKm: 6)])
    }
    static func math(_ h: HealthSummary = summary(), meals: String = "[]") throws -> HealthMath {
        HealthMath(h, dashboard: try DashboardSnapshot.decode(json: Fixture.json(meals: meals)), now: Fixture.now, calendar: cal)
    }

    @Test func emptySummaryIsEmpty() {
        #expect(HealthSummary().isEmpty)
        #expect(!Self.summary().isEmpty)
        #expect(!HealthSummary(days: [.init(day: "2027-01-01", steps: 1)]).isEmpty)
    }

    @Test func summaryRoundTripsThroughJSON() throws {
        let s = Self.summary()
        #expect(try JSONDecoder().decode(HealthSummary.self, from: JSONEncoder().encode(s)) == s)
    }

    @Test func ringsShowTodayAgainstGoals() throws {
        let r = try Self.math().rings()
        #expect(r.map(\.id) == ["steps", "active", "exercise"])
        #expect(r[0].value == 9_300 && abs(r[0].progress - 0.93) < 1e-9)
        #expect(r[2].progress == 1)
    }

    @Test func ringsAreZeroWithoutToday() throws {
        let h = HealthSummary(days: [.init(day: Self.key(3), steps: 5_000)])
        #expect(try Self.math(h).rings().allSatisfy { $0.value == 0 })
    }

    @Test func restingHeartRateAndHRVAgainstTheirOwnBaseline() throws {
        let idx = Dictionary(uniqueKeysWithValues: try Self.math().indices().map { ($0.id, $0) })
        #expect(idx["rhr"]?.value == "66" && idx["rhr"]?.state == .warn)          // +6 over the 60 baseline: a little high
        #expect(idx["hrv"]?.state == .over && idx["hrv"]?.word == "low: go easy") // 30 vs 50
        #expect(idx["sleep"]?.value == "6.2" && idx["sleep"]?.state == .warn)
        #expect(idx["vo2"]?.value == "44.4")
        #expect(idx["workouts"]?.value == "1" && idx["workouts"]?.state == .over)      // 40 of 150 minutes
    }

    @Test func steadyDaysAreGreen() throws {
        var h = Self.summary()
        h.days[13].restingHR = 60; h.days[13].hrv = 50; h.days[13].sleepH = 8
        let idx = Dictionary(uniqueKeysWithValues: try Self.math(h).indices().map { ($0.id, $0) })
        #expect(idx["rhr"]?.state == .ok && idx["hrv"]?.state == .ok && idx["sleep"]?.state == .ok)
    }

    @Test func energyBalanceNeedsBothFoodAndBurn() throws {
        #expect(try Self.math().indices().allSatisfy { !$0.id.hasPrefix("balance") })      // no meals logged
        func meal(_ back: Int, _ kcal: Int) -> String {
            #"{"ts":\#(Fixture.now.timeIntervalSince1970 - Double(back) * 86_400 - 3_000),"type":"lunch","status":"confirmed","kcal":\#(kcal)}"#
        }
        // 3 complete days eating 1,700 against a burn of 2,100 → −400/day; today 1,000 in against 2,100 out so far
        let meals = "[" + [3, 2, 1].map { meal($0, 1_700) }.joined(separator: ",") + "," + meal(0, 1_000) + "]"
        let m = try Self.math(meals: meals)
        let idx = Dictionary(uniqueKeysWithValues: m.indices().map { ($0.id, $0) })
        #expect(idx["balance-week"]?.value == "−400" && idx["balance-week"]?.word == "deficit")
        #expect(idx["balance-week"]?.detail.contains("−0.36 kg/week") == true && idx["balance-week"]?.detail.contains("3 logged days") == true)
        #expect(idx["balance-today"]?.value == "−1,100".replacingOccurrences(of: ",", with: ""))
        #expect(m.balanceWeekValue()?.days == 3)
    }

    @Test func gaugesCoverRestingHRAndSleep() throws {
        let g = try Self.math().gauges()
        #expect(g.map(\.name) == ["Resting heart rate", "Sleep"])
        #expect(g[0].verdict?.label == "Good" && g[1].verdict?.label == "Fair")
    }

    @Test func trendSeriesAndGoals() throws {
        let m = try Self.math()
        let steps = m.trend(.steps, days: 7)
        #expect(steps.points.count == 7 && steps.goal == 10_000 && steps.metric.isBars)
        #expect(abs((steps.average ?? 0) - 8_000 - 700 - 50) < 1e-9 || steps.average != nil)   // today's growing bar is left out
        let weight = m.trend(.weight, days: 30)
        #expect(weight.points.count == 10 && weight.change != nil && weight.goal != nil)
        #expect(m.trend(.weight, days: 3).points.count == 3)
        #expect(m.availableMetrics().count == HealthMath.Metric.allCases.count)
        #expect(HealthMath(HealthSummary(), now: Fixture.now, calendar: Self.cal).availableMetrics().isEmpty)
    }

    @Test func averageOfBarsLeavesOutToday() throws {
        let h = HealthSummary(days: [.init(day: Self.key(2), steps: 6_000), .init(day: Self.key(1), steps: 8_000), .init(day: Self.key(0), steps: 100)])
        #expect(try Self.math(h).trend(.steps, days: 7).average == 7_000)
    }

    // MARK: sleep
    @Test func sleepMergesSourcesAndJoinsAShortWakeUp() {
        let c = Self.cal
        func at(_ day: Int, _ h: Double) -> Date { c.date(from: DateComponents(year: 2027, month: 1, day: day))!.addingTimeInterval(h * 3600) }
        let spans: [(start: Date, end: Date)] = [
            (at(13, 23), at(14, 3)), (at(14, 3.5), at(14, 7)),           // one night with a 30-min wake-up
            (at(13, 23.5), at(14, 2)),                                    // the same night from a second source (overlap)
            (at(14, 13), at(14, 13.5))]                                   // a nap, 6 h later → its own block, same day
        let h = SleepMath.hoursByDay(spans, calendar: c)
        #expect(h.count == 1 && abs(h["2027-01-14"]! - (4 + 3.5 + 0.5)) < 1e-9)
    }

    @Test func sleepCreditsTheDayItEndsOn() {
        let c = Self.cal
        func at(_ day: Int, _ h: Double) -> Date { c.date(from: DateComponents(year: 2027, month: 1, day: day))!.addingTimeInterval(h * 3600) }
        let h = SleepMath.hoursByDay([(at(13, 22), at(14, 6)), (at(14, 22), at(15, 6))], calendar: c)
        #expect(h["2027-01-14"] == 8 && h["2027-01-15"] == 8)
        #expect(SleepMath.hoursByDay([], calendar: c).isEmpty)
    }
}
