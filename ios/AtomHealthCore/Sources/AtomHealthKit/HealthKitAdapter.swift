import AtomHealthCore
import Foundation

/// Marker so the module is never empty on platforms without HealthKit (the package is also tested on macOS).
public enum AtomHealthKitInfo { public static let available: Bool = {
    #if os(iOS) && canImport(HealthKit)
    true
    #else
    false
    #endif
}() }

#if os(iOS) && canImport(HealthKit)
import HealthKit

public enum HealthKitError: Error { case unavailable, denied }

enum HK {
    static let bodyMass = HKQuantityType(.bodyMass)
    static let bodyFat = HKQuantityType(.bodyFatPercentage)
    static let leanMass = HKQuantityType(.leanBodyMass)
    static let energy = HKQuantityType(.dietaryEnergyConsumed)
    static let protein = HKQuantityType(.dietaryProtein)
    static let carbs = HKQuantityType(.dietaryCarbohydrates)
    static let fat = HKQuantityType(.dietaryFatTotal)
    static let fiber = HKQuantityType(.dietaryFiber)
    static let active = HKQuantityType(.activeEnergyBurned)
    static let basal = HKQuantityType(.basalEnergyBurned)
    static let steps = HKQuantityType(.stepCount)
    static let food = HKCorrelationType(.food)
    static let workout = HKObjectType.workoutType()

    static let kg = HKUnit.gramUnit(with: .kilo), g = HKUnit.gram(), kcal = HKUnit.kilocalorie(), pct = HKUnit.percent()
    static let readTypes: Set<HKObjectType> = [bodyMass, bodyFat, leanMass, energy, protein, carbs, fat, fiber, active, basal, steps, workout]
    static let writeTypes: Set<HKSampleType> = [bodyMass, bodyFat, leanMass, energy, protein, carbs, fat, fiber, food]

    /// Samples written by this app. HealthKit only lets an app edit or delete what it wrote itself.
    static var ownSource: NSPredicate { HKQuery.predicateForObjects(from: HKSource.default()) }
    static var otherSources: NSPredicate { NSCompoundPredicate(notPredicateWithSubpredicate: ownSource) }

    static func syncID(_ kind: String, _ id: String) -> String { "atomhealth:\(kind):\(id)" }
    static func meta(_ kind: String, _ id: String, _ version: Int) -> [String: Any] {
        [HKMetadataKeySyncIdentifier: syncID(kind, id), HKMetadataKeySyncVersion: version]
    }
}

/// Writes Mac-originated weights and confirmed meals into Apple Health.
/// A new version of the same sync identifier replaces the earlier sample (HealthKit does this natively).
public final class HealthKitSink: InboundSink, @unchecked Sendable {
    let store: HKHealthStore
    public init(store: HKHealthStore = HKHealthStore()) { self.store = store }

    public func apply(_ env: Envelope) async throws {
        switch try HealthWrite.decode(env) {
        case let .weight(id, version, date, kg, fat, lean):
            var samples = [HKQuantitySample(type: HK.bodyMass, quantity: .init(unit: HK.kg, doubleValue: kg),
                                            start: date, end: date, metadata: HK.meta("weight", id, version))]
            if let fat { samples.append(.init(type: HK.bodyFat, quantity: .init(unit: HK.pct, doubleValue: fat / 100),
                                              start: date, end: date, metadata: HK.meta("weight-fat", id, version))) }
            if let lean { samples.append(.init(type: HK.leanMass, quantity: .init(unit: HK.kg, doubleValue: lean),
                                               start: date, end: date, metadata: HK.meta("weight-lean", id, version))) }
            try await store.save(samples)
        case let .meal(id, version, date, caption, mealType, kcal, protein, carbs, fat, fiber):
            let m = HK.meta("meal", id, version)
            func q(_ t: HKQuantityType, _ unit: HKUnit, _ v: Double?, _ k: String) -> HKQuantitySample? {
                v.map { HKQuantitySample(type: t, quantity: .init(unit: unit, doubleValue: $0), start: date, end: date, metadata: HK.meta("meal-\(k)", id, version)) }
            }
            let parts = [q(HK.energy, HK.kcal, kcal, "kcal"), q(HK.protein, HK.g, protein, "protein"), q(HK.carbs, HK.g, carbs, "carbs"),
                         q(HK.fat, HK.g, fat, "fat"), q(HK.fiber, HK.g, fiber, "fiber")].compactMap { $0 }
            var meta = m
            if let caption { meta[HKMetadataKeyFoodType] = caption }
            if let mealType { meta["atomhealth_meal_type"] = mealType }
            let food = HKCorrelation(type: HK.food, start: date, end: date, objects: Set(parts), metadata: meta)
            try await store.save(food)
        case let .remove(type, id, _):
            try await remove(type: type, id: id)
        }
    }

    func remove(type: EnvelopeType, id: String) async throws {
        let kinds = type == .weight ? ["weight", "weight-fat", "weight-lean"] : ["meal"]
        let ids = kinds.map { HK.syncID($0, id) }
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: ids), HK.ownSource])
        var doomed: [HKObject] = []
        for t in (type == .weight ? [HK.bodyMass, HK.bodyFat, HK.leanMass] : [HK.food]) as [HKSampleType] {
            let found: [HKSample] = try await withCheckedThrowingContinuation { cont in
                store.execute(HKSampleQuery(sampleType: t, predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, r, e in
                    if let e { cont.resume(throwing: e) } else { cont.resume(returning: r ?? []) } })
            }
            for s in found { doomed.append(s); if let c = s as? HKCorrelation { doomed += Array(c.objects) } }
        }
        if !doomed.isEmpty { try await store.delete(doomed) }
    }
}

/// Watches Health for changes made by other apps and devices and queues them for the relay.
/// Samples this app wrote itself are excluded by source, so Mac data never echoes back.
public final class HealthKitReader: @unchecked Sendable {
    let store: HKHealthStore
    let state: JSONFileStateStore
    let calendar: Calendar
    var observers: [HKObserverQuery] = []
    public var onChange: (@Sendable () -> Void)?   // call SyncEngine.cycle() (debounced) from here

    public init(store: HKHealthStore = HKHealthStore(), state: JSONFileStateStore, calendar: Calendar = .current) {
        self.store = store; self.state = state; self.calendar = calendar
    }

    public func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthKitError.unavailable }
        try await store.requestAuthorization(toShare: HK.writeTypes, read: HK.readTypes)
    }

    /// Registers observers and background delivery, then does an initial catch-up.
    public func start() async throws {
        let types: [HKSampleType] = [HK.bodyMass, HK.bodyFat, HK.leanMass, HK.active, HK.basal, HK.steps,
                                     HK.energy, HK.protein, HK.carbs, HK.fat, HK.fiber, HK.workout]
        for t in types {
            let q = HKObserverQuery(sampleType: t, predicate: nil) { [weak self] _, done, _ in
                guard let self else { return done() }
                // HealthKit's completion handler is not Sendable; it must be called exactly once, after the refresh.
                nonisolated(unsafe) let finish = done
                Task { await self.refresh(); self.onChange?(); finish() }
            }
            store.execute(q); observers.append(q)
            try? await store.enableBackgroundDelivery(for: t, frequency: .immediate)
        }
        await refresh()
    }

    public func refresh() async {
        await readBodyMass()
        await readWorkouts()
        await dayTotals(days: 14)
    }

    // MARK: anchored, incremental reads (weight, workouts)
    func anchor(_ key: String) async -> HKQueryAnchor? {
        guard let d = await state.blob("anchor.\(key)") else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: d)
    }
    func saveAnchor(_ a: HKQueryAnchor?, _ key: String) async {
        let d = a.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        await state.setBlob(d, for: "anchor.\(key)")
    }

    func anchored(_ type: HKSampleType, key: String) async -> ([HKSample], [HKDeletedObject], HKQueryAnchor?) {
        let start = await anchor(key)
        return await withCheckedContinuation { cont in
            store.execute(HKAnchoredObjectQuery(type: type, predicate: HK.otherSources, anchor: start, limit: HKObjectQueryNoLimit) { _, s, d, a, _ in
                cont.resume(returning: (s ?? [], d ?? [], a)) })
        }
    }

    func readBodyMass() async {
        let (samples, deleted, newAnchor) = await anchored(HK.bodyMass, key: "bodyMass")
        for case let s as HKQuantitySample in samples {
            let near = { (t: HKQuantityType) async -> Double? in await self.nearest(t, to: s.startDate) }
            let fat = await near(HK.bodyFat).map { $0 * 100 }
            let lean = await near(HK.leanMass)
            await state.enqueue(HealthMapping.weightChange(uuid: s.uuid.uuidString, date: s.startDate,
                                                           kg: s.quantity.doubleValue(for: HK.kg), fatPct: fat, leanKg: lean))
        }
        for d in deleted { await state.enqueue(HealthMapping.deletion(type: .weight, id: "hk:\(d.uuid.uuidString)")) }
        await saveAnchor(newAnchor, "bodyMass")
    }

    /// Body composition recorded by a smart scale lands as separate samples within seconds of the weight.
    func nearest(_ type: HKQuantityType, to date: Date) async -> Double? {
        let window = HKQuery.predicateForSamples(withStart: date.addingTimeInterval(-120), end: date.addingTimeInterval(120))
        let p = NSCompoundPredicate(andPredicateWithSubpredicates: [window, HK.otherSources])
        return await withCheckedContinuation { cont in
            store.execute(HKSampleQuery(sampleType: type, predicate: p, limit: 1, sortDescriptors: nil) { _, r, _ in
                let v = (r?.first as? HKQuantitySample)?.quantity
                cont.resume(returning: v?.doubleValue(for: type == HK.bodyFat ? HK.pct : HK.kg)) })
        }
    }

    func readWorkouts() async {
        let (samples, deleted, newAnchor) = await anchored(HK.workout, key: "workout")
        for case let w as HKWorkout in samples {
            let kcal = w.statistics(for: HK.active)?.sumQuantity()?.doubleValue(for: HK.kcal)
            let dist = w.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()?.doubleValue(for: .meter())
            await state.enqueue(HealthMapping.workoutChange(uuid: w.uuid.uuidString, start: w.startDate, end: w.endDate,
                                                            type: String(describing: w.workoutActivityType.rawValue), kcal: kcal, distanceM: dist))
        }
        for d in deleted { await state.enqueue(HealthMapping.deletion(type: .workout, id: "hk:\(d.uuid.uuidString)")) }
        await saveAnchor(newAnchor, "workout")
    }

    // MARK: per-day totals (activity from all sources; nutrition from other apps only)
    func dayTotals(days: Int) async {
        let end = Date(), start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end)
        let step = DateComponents(day: 1)
        func sums(_ t: HKQuantityType, _ unit: HKUnit, other: Bool) async -> [String: Double] {
            await withCheckedContinuation { cont in
                let q = HKStatisticsCollectionQuery(quantityType: t, quantitySamplePredicate: other ? HK.otherSources : nil,
                                                    options: .cumulativeSum, anchorDate: start, intervalComponents: step)
                q.initialResultsHandler = { _, c, _ in
                    var out: [String: Double] = [:]
                    c?.enumerateStatistics(from: start, to: end) { s, _ in
                        if let v = s.sumQuantity()?.doubleValue(for: unit) { out[HealthMapping.dayKey(s.startDate, calendar: self.calendar)] = v } }
                    cont.resume(returning: out) }
                store.execute(q)
            }
        }
        let active = await sums(HK.active, HK.kcal, other: false), basal = await sums(HK.basal, HK.kcal, other: false)
        let steps = await sums(HK.steps, .count(), other: false)
        let kcal = await sums(HK.energy, HK.kcal, other: true), prot = await sums(HK.protein, HK.g, other: true)
        let carb = await sums(HK.carbs, HK.g, other: true), fat = await sums(HK.fat, HK.g, other: true), fib = await sums(HK.fiber, HK.g, other: true)
        for day in Set(active.keys).union(basal.keys).union(steps.keys).sorted() {
            let c = HealthMapping.activityDayChange(day: day, activeKcal: active[day], basalKcal: basal[day], steps: steps[day])
            await enqueueIfChanged(c, key: "fp.activity.\(day)")
        }
        for day in kcal.keys.sorted() {
            let c = HealthMapping.nutritionDayChange(day: day, kcal: kcal[day], protein: prot[day], carbs: carb[day], fat: fat[day], fiber: fib[day])
            await enqueueIfChanged(c, key: "fp.nutrition.\(day)")
        }
    }

    /// Day totals are recomputed often; only queue a day when its numbers actually changed.
    func enqueueIfChanged(_ c: LocalChange, key: String) async {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        guard let fp = try? enc.encode(c.data), await state.blob(key) != fp else { return }
        await state.setBlob(fp, for: key)
        await state.enqueue(c)
    }
}
#endif
