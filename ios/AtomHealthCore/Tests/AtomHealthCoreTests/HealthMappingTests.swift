import Foundation
import Testing
@testable import AtomHealthCore

private func envelope(_ type: EnvelopeType, _ data: [String: JSONValue], op: Envelope.Op = .upsert) -> Envelope {
    Envelope(type: type, op: op, id: "x1", version: 9, updatedAt: 0, data: op == .delete ? nil : .object(data))
}
private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test func dayKeyUsesTheCalendarTimeZone() {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Pacific/Auckland")!
    let d = Date(timeIntervalSince1970: 1_700_000_000)            // 2023-11-14 22:13 UTC = 2023-11-15 11:13 NZDT
    #expect(HealthMapping.dayKey(d, calendar: cal) == "2023-11-15")
    cal.timeZone = TimeZone(identifier: "UTC")!
    #expect(HealthMapping.dayKey(d, calendar: cal) == "2023-11-14")
}

@Test func outboundShapesMatchWhatTheMacValidates() throws {
    let w = HealthMapping.weightChange(uuid: "ABC", date: Date(timeIntervalSince1970: 1_700_000_000.4), kg: 78.4, fatPct: 21)
    #expect(w.id == "hk:ABC" && w.data?["ts"]?.doubleValue == 1_700_000_000 && w.data?["lean_kg"] == nil)
    let a = HealthMapping.activityDayChange(day: "2026-11-13", activeKcal: 555, basalKcal: nil, steps: 8000.4)
    #expect(a.id == "day:2026-11-13" && a.data?["steps"]?.doubleValue == 8000 && a.data?["day"]?.stringValue == "2026-11-13")
    let n = HealthMapping.nutritionDayChange(day: "2026-11-13", kcal: 2100, protein: 120, carbs: nil, fat: nil, fiber: nil)
    #expect(n.type == .nutritionDay && n.data?["kcal"]?.doubleValue == 2100)
    let k = HealthMapping.workoutChange(uuid: "W1", start: Date(timeIntervalSince1970: 1_700_000_000), end: nil, type: "running", kcal: 300, distanceM: 5000)
    #expect(k.data?["start_ts"]?.doubleValue == 1_700_000_000 && k.data?["end_ts"] == nil)
    #expect(HealthMapping.deletion(type: .weight, id: "hk:ABC").op == .delete)
}

@Test func decodesInboundWeightAndMealFromMac() throws {
    let w = try HealthWrite.decode(envelope(.weight, ["ts": .number(1_700_000_000), "weight_kg": .number(77.7), "impedance": .number(500)]), now: now)
    #expect(w == .weight(id: "x1", version: 9, date: Date(timeIntervalSince1970: 1_700_000_000), kg: 77.7, fatPct: nil, leanKg: nil))
    let m = try HealthWrite.decode(envelope(.meal, ["ts": .number(1_700_000_000), "kcal": .number(450), "protein_g": .number(25),
                                                     "caption": .string("pasta"), "meal_type": .string("lunch"), "items": .array([])]), now: now)
    guard case .meal(_, _, _, let cap, let mt, let kcal, let p, let c, _, _) = m else { Issue.record("not a meal"); return }
    #expect(cap == "pasta" && mt == "lunch" && kcal == 450 && p == 25 && c == nil)
    #expect(try HealthWrite.decode(envelope(.weight, [:], op: .delete), now: now) == .remove(type: .weight, id: "x1", version: 9))
}

@Test func rejectsOutOfRangeMissingAndUnsupported() {
    func bad(_ e: Envelope) -> Bool { (try? HealthWrite.decode(e, now: now)) == nil }
    #expect(bad(envelope(.weight, ["ts": .number(1_700_000_000), "weight_kg": .number(5)])))            // too light
    #expect(bad(envelope(.weight, ["ts": .number(1_700_000_000)])))                                      // missing weight
    #expect(bad(envelope(.weight, ["ts": .number(100), "weight_kg": .number(70)])))                      // before 2000
    #expect(bad(envelope(.weight, ["ts": .number(now.timeIntervalSince1970 + 999_999), "weight_kg": .number(70)])))  // future
    #expect(bad(envelope(.weight, ["ts": .number(1_700_000_000), "weight_kg": .bool(true)])))            // bool is not a number
    #expect(bad(envelope(.weight, ["ts": .number(1_700_000_000), "weight_kg": .number(70), "fat_pct": .number(99)])))
    #expect(bad(envelope(.workout, ["ts": .number(1_700_000_000)])))                                     // phone does not ingest workouts
    #expect(bad(envelope(.meal, ["ts": .number(1_700_000_000), "kcal": .number(-1)])))
}

@Test func fileStorePersistsEverythingAcrossRestarts() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let a = JSONFileStateStore(url: url)
    await a.setCursor(42)
    await a.setVersion(7, of: .weight, id: "w1")
    await a.enqueue(HealthMapping.weightChange(uuid: "U1", date: Date(timeIntervalSince1970: 1_700_000_000), kg: 80))
    await a.enqueue(HealthMapping.deletion(type: .weight, id: "hk:U2"))
    await a.setBlob(Data([1, 2, 3]), for: "anchor.bodyMass")
    await a.removePending(count: 1)
    let b = JSONFileStateStore(url: url)
    let cur = await b.cursor(), ver = await b.version(of: .weight, id: "w1"), blob = await b.blob("anchor.bodyMass")
    #expect(cur == 42 && ver == 7 && blob == Data([1, 2, 3]))
    let q = await b.pending()
    #expect(q.count == 1 && q[0].op == .delete)
    let fresh = await JSONFileStateStore(url: url.appendingPathExtension("missing")).cursor()
    #expect(fresh == 0)
}
