import Foundation
import Testing
@testable import AtomHealthCore

/// A synthetic snapshot shaped like `app.dashboard_snapshot()` (snake_case JSON): 10 daily weigh-ins, the last one 85 kg, losing 0.2 kg/day.
enum Fixture {
    static let day = 86_400.0
    static let t0 = 1_800_000_000.0                      // last weigh-in
    static var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    static var now: Date { Date(timeIntervalSince1970: t0 + 3600) }

    static func json(meals: String = "[]", target: String = "null") -> Data {
        let rows = (0..<10).map { i -> String in
            let w = 85.0 + 0.2 * Double(9 - i), ts = t0 - Double(9 - i) * day
            return #"{"ts":\#(ts),"weight":\#(w),"bmi":\#(w / 3.24),"fat_pct":\#(24 + 0.1 * Double(9 - i)),"lean_kg":60.0,"muscle_kg":31.0,"water_pct":55.5,"tbw_kg":45.0,"ffmi":18.5,"nffmi":18.0,"fmi":6.0}"#
        }.joined(separator: ",")
        return Data("""
        {"profile":{"height_cm":180,"age":40,"sex":"male","target_weight":\(target),"target_fat_pct":null,"target_date":null},
         "healthy_range":[60.0,81.0],"optimal":{"weight":71.3,"fat_pct_range":[11,21],"fat_pct":16.0},
         "ref":{"bmi_zones":[{"label":"Underweight","from":15,"to":18.5,"cls":"z1"},{"label":"Healthy","from":18.5,"to":25,"cls":"z2"},
                {"label":"Overweight","from":25,"to":30,"cls":"z4"},{"label":"Obese I","from":30,"to":40,"cls":"z5"}],
                "fat_zones":[{"label":"Athletic","from":6,"to":14,"cls":"z2"},{"label":"Average","from":14,"to":25,"cls":"z4"},{"label":"High","from":25,"to":45,"cls":"z6"}],
                "ffmi_zones":[{"label":"Average","from":10,"to":20,"cls":"z3"},{"label":"Excellent","from":20,"to":32,"cls":"z2"}],
                "water_range":[50,65]},
         "nutrition":{"goal":"lose","kcal":2000,"weight":83.2,"protein_per_kg":1.6,"protein_basis_kg":76.9,
                      "macros":[{"key":"protein","label":"Protein","g":120,"kcal":480,"pct":24},{"key":"carbs","label":"Carbs","g":200,"kcal":800,"pct":40},{"key":"fat","label":"Fat","g":80,"kcal":720,"pct":36}],
                      "limits":{"fiber_g":28,"water_l":2.7},"meals":[{"label":"Breakfast","kcal":500,"pct":25}],"warnings":[]},
         "first":{"ts":\(t0 - 90 * day),"weight":90.0,"fat_pct":27.0},
         "readings":[\(rows)],"meals":\(meals),"advice":{"today":[],"week":null,"removed":1},"generated_at":\(t0)}
        """.utf8)
    }
    static func math(meals: String = "[]", target: String = "null") throws -> DashboardMath {
        DashboardMath(try DashboardSnapshot.decode(json: json(meals: meals, target: target)), now: now, calendar: utc)
    }
}

@Suite struct DashboardTests {
    @Test func decodesSnakeCaseAndToleratesMissingParts() throws {
        let s = try DashboardSnapshot.decode(json: Fixture.json())
        #expect(s.readings.count == 10 && s.profile.heightCm == 180 && s.nutrition?.limits?.fiberG == 28)
        let sparse = try DashboardSnapshot.decode(json: Data(#"{"profile":{},"readings":[],"meals":[]}"#.utf8))
        #expect(sparse.optimal == nil && sparse.nutrition == nil)
        let m = DashboardMath(sparse)
        #expect(m.kpis().isEmpty && m.gauges().isEmpty && m.goals().isEmpty && m.indicators().isEmpty && m.weightGauge() == nil)
    }

    @Test func zonesClampAtBothEnds() throws {
        let z = try Fixture.math().s.ref!.bmiZones
        #expect(DashboardMath.zone(22, in: z)?.label == "Healthy")
        #expect(DashboardMath.zone(5, in: z)?.label == "Underweight")
        #expect(DashboardMath.zone(99, in: z)?.label == "Obese I")
        #expect(DashboardMath.zone(nil, in: z) == nil)
    }

    @Test func kpisCarryDeltasAveragesTargetsAndSparklines() throws {
        let k = try Fixture.math().kpis()
        let w = try #require(k.first { $0.id == "weight" })
        let since = try #require(w.deltaSinceLast), vsAvg = try #require(w.deltaVsAverage)
        #expect(w.value == 85.0 && abs(since - (-0.2)) < 1e-9 && w.spark.count == 10)
        #expect(w.averageCount == 7 && vsAvg < 0)
        #expect(w.targetText == "71.3 kg optimal · −13.7 to go")
        #expect(k.first { $0.id == "water_pct" }?.zone?.label == "Typical")
        #expect(k.first { $0.id == "fat_pct" }?.targetText == "16.0% optimal · −8.0 to go")
    }

    @Test func explicitTargetIsLabelledTargetAndReached() throws {
        let m = try Fixture.math(target: "85.2")
        let w = try #require(m.kpis().first { $0.id == "weight" })
        #expect(w.targetReached && w.targetText?.contains("target · reached") == true)
    }

    @Test func gaugesFollowTheWebDashboard() throws {
        let m = try Fixture.math()
        let g = try #require(m.weightGauge())
        #expect(abs(g.min - 15 * 1.8 * 1.8) < 1e-9 && g.verdict?.label == "Overweight")
        #expect(g.note.contains("above the healthy upper limit"))
        let names = m.gauges().map(\.name)
        #expect(names == ["Body Mass Index", "Body fat (estimate)", "Body water (estimate)", "Fat-free mass index (FFMI)"])
        #expect(m.gauges()[1].note.contains("points above it"))
    }

    @Test func goalPaceEtaAndOutlook() throws {
        let m = try Fixture.math()
        let g = try #require(m.goals().first)
        #expect(g.title == "Weight goal" && g.isOptimal && g.status == .onTrack)
        let pace = try #require(g.weeklyPace)
        #expect(abs(pace - (-1.4)) < 0.05)                                       // 0.2 kg/day
        #expect(g.eta != nil && g.progress > 0.2 && g.progress < 0.5)           // (90-85)/(90-71.3)
        #expect(m.goals().count == 2 && m.goalNote()?.hasPrefix("For 180 cm: healthy 60–81 kg") == true)
    }

    @Test func movingAwayAndTooLittleDataAreReported() throws {
        var s = try DashboardSnapshot.decode(json: Fixture.json())
        s.readings = s.readings.map { var r = $0; r.weight = 170 - r.weight; return r }   // now gaining
        #expect(DashboardMath(s).goals().first?.status == .offTrack)
        s.readings = Array(s.readings.suffix(2))
        #expect(DashboardMath(s).goals().first?.status == .needData)
    }

    @Test func todaysNutritionUsesOnlySavedMealsFromToday() throws {
        let today = Fixture.t0 + 1800, yesterday = Fixture.t0 - 7200 - 86_400
        let meals = """
        [{"ts":\(today),"type":"lunch","status":"confirmed","kcal":1000,"protein_g":90,"carbs_g":100,"fat_g":40,"fiber_g":10,"items":["rice"]},
         {"ts":\(today),"type":"snack","status":"pending","kcal":500,"protein_g":5,"carbs_g":5,"fat_g":5,"fiber_g":1,"items":[]},
         {"ts":\(yesterday),"type":"dinner","status":"confirmed","kcal":900,"protein_g":50,"carbs_g":50,"fat_g":50,"fiber_g":5,"items":[]}]
        """
        let m = try Fixture.math(meals: meals)
        #expect(m.todayMeals.count == 2 && m.todaySaved.count == 1 && m.todayTotals().kcal == 1000)
        let ind = m.indicators()
        #expect(ind.map(\.name) == ["Energy", "Protein", "Carbs", "Fat", "Fibre"])
        #expect(ind[0].state == .low && ind[0].detail == "1000 kcal left" && ind[1].word == "almost there")
        #expect(ind[3].state == .low && ind[2].state == .low)
        let c = m.coachCalculation()
        #expect(c.headline == "Today: 1,000 / 2,000 kcal · 1,000 left" && c.mealCount == 1)
        let tiles = m.indices()
        #expect(tiles.map(\.title) == ["Macro split", "Protein per kg", "Fibre density", "7-day average"])
        #expect(tiles[3].detail.hasPrefix("2 logged days"))          // today + yesterday are within 7 days
    }

    @Test func nStateThresholds() {
        #expect(DashboardMath.nState(1.2, reach: false) == .over && DashboardMath.nState(1.1, reach: false) == .warn)
        #expect(DashboardMath.nState(0.9, reach: false) == .ok && DashboardMath.nState(0.5, reach: false) == .low)
        #expect(DashboardMath.nState(1, reach: true) == .ok && DashboardMath.nState(0.7, reach: true) == .warn && DashboardMath.nState(0.3, reach: true) == .low)
    }

    @Test func formatting() {
        #expect(Fmt.signed(-0.24, 1) == "−0.2" && Fmt.signed(2, 1) == "+2.0" && Fmt.thousands(1872) == "1,872")
        #expect(Fmt.num(83.25, 1) == "83.3" && Fmt.num(-83.25, 1) == "-83.3" && Fmt.num(2.5, 0) == "3")   // as JavaScript toFixed
        #expect(Fmt.trim(64.0) == "64" && Fmt.trim(76.9) == "76.9" && Fmt.num(nil) == "—")
    }

    @Test func storeKeepsTheLatestSnapshotAndIgnoresGarbage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dash-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DashboardStore(url: url)
        #expect(await store.load() == nil)
        let good = try JSONDecoder().decode(JSONValue.self, from: Fixture.json())
        await store.apply(Envelope(type: .dashboard, op: .upsert, id: "overview", version: 1, updatedAt: 0, data: good))
        let loaded = await store.load()
        #expect(loaded?.readings.count == 10)
        await store.apply(Envelope(type: .dashboard, op: .upsert, id: "overview", version: 2, updatedAt: 0, data: .object(["nonsense": .bool(true)])))
        #expect(await store.load()?.readings.count == 10)              // garbage did not replace it
        await store.apply(Envelope(type: .dashboard, op: .delete, id: "overview", version: 3, updatedAt: 0, data: nil))
        #expect(await store.load() == nil)
    }

    @Test func routingSendsDashboardAwayFromHealth() async throws {
        actor Spy: InboundSink { var seen: [EnvelopeType] = []
            func apply(_ env: Envelope) { seen.append(env.type) }
            func types() -> [EnvelopeType] { seen } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dash-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let chat = ChatStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString)"))
        let spy = Spy(), sink = RoutingSink(health: spy, dashboard: DashboardStore(url: url), chat: chat)
        let good = try JSONDecoder().decode(JSONValue.self, from: Fixture.json())
        try await sink.apply(Envelope(type: .dashboard, op: .upsert, id: "overview", version: 1, updatedAt: 0, data: good))
        try await sink.apply(Envelope(type: .weight, op: .delete, id: "w", version: 1, updatedAt: 0, data: nil))
        try await sink.apply(Envelope(type: .chatOut, op: .upsert, id: "m1", version: 1, updatedAt: 5,
                                      data: .object(["mid": .number(1), "text": .string("hi")])))
        #expect(await spy.types() == [.weight])                     // chat never reaches HealthKit
        #expect(await chat.snapshot().messages.map(\.text) == ["hi"])
        #expect(SyncEngine.inboundTypes.contains(.dashboard))
    }
}
