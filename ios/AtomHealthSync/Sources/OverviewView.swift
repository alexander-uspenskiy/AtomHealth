import AtomHealthCore
import SwiftUI

/// The Overview tab: the latest weight, then the charts and critical indexes (Apple Health read on this phone, plus the
/// energy balance that joins it with the Mac's meals), then the Mac dashboard's scale, coach, nutrition, gauges and goals.
/// Pull down to sync.
struct OverviewView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                let m = model.dashboard.map { DashboardMath($0) }
                let hm = model.health.map { HealthMath($0, dashboard: model.dashboard) }
                let hasHealth = !(model.health?.isEmpty ?? true)
                if m == nil && !hasHealth {
                    empty.padding(24)
                } else {
                    LazyVStack(spacing: 14) {
                        if let m, let r = m.latest, let s = model.dashboard { hero(r, s) }
                        // charts and the most critical indexes first
                        if let hm, hasHealth {
                            TrendCard(m: hm)
                            RingsCard(m: hm)
                            let idx = hm.indices()
                            if !idx.isEmpty { IndexGrid(items: idx) }
                            let hg = hm.gauges()
                            if !hg.isEmpty {
                                Card(title: "Heart and sleep", subtitle: "Where your latest values sit on the usual scales") {
                                    ForEach(Array(hg.enumerated()), id: \.offset) { n, g in
                                        if n > 0 { Divider() }
                                        RangeGauge(g: g)
                                    }
                                }
                            }
                        } else {
                            HealthEmptyCard(busy: model.busy) { Task { await model.syncNow() } }
                        }
                        if let m {
                            if let g = m.weightGauge() { Card { RangeGauge(g: g) } }
                            kpiGrid(m)
                            coach(m)
                            today(m)
                            stand(m)
                            goals(m)
                        }
                        if let w = model.health?.workouts, !w.isEmpty { workouts(w) }
                    }
                    .padding(16)
                }
            }
            .background(Color(.systemGroupedBackground))
            .appTabBar(model)
            .navigationTitle("Overview")
            .refreshable { await model.syncNow() }
        }
    }

    // MARK: pieces
    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath.icloud").font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text("Waiting for your Mac").font(.title3.weight(.semibold))
            Text("The Overview appears after the Mac's next sync, within a few minutes. Pull down to check now.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(model.busy ? "Syncing…" : "Sync now") { Task { await model.syncNow() } }
                .buttonStyle(.borderedProminent).disabled(model.busy)
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }

    private func hero(_ r: DashboardSnapshot.Reading, _ s: DashboardSnapshot) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LATEST READING").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(Fmt.num(r.weight, 2)).font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("kg").font(.headline).foregroundStyle(.white.opacity(0.85))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Measured \(r.date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.white.opacity(0.9))
                if let b = r.bmi { Text("BMI \(Fmt.num(b, 1))").font(.caption.weight(.semibold)) }
                if let f = r.fatPct { Text("Body fat \(Fmt.num(f, 1))%").font(.caption.weight(.semibold)) }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 14)
        .background(LinearGradient(colors: [Color(hex: 0x4F46E5), Color(hex: 0x2563EB), Color(hex: 0x0EA5A4)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func workouts(_ list: [HealthSummary.Workout]) -> some View {
        Card(title: "Recent workouts", subtitle: "Last 7 days, from Apple Health") {
            VStack(spacing: 0) {
                ForEach(Array(list.prefix(6).enumerated()), id: \.element.id) { n, w in
                    if n > 0 { Divider() }
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.kind).font(.subheadline.weight(.semibold))
                            Text(w.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Int(w.minutes.rounded())) min").font(.subheadline.weight(.semibold)).monospacedDigit()
                            Text([w.kcal.map { "\(Int($0.rounded())) kcal" }, w.distanceKm.map { "\(Fmt.num($0, 1)) km" }]
                                .compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func kpiGrid(_ m: DashboardMath) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(m.kpis()) { KPICard(k: $0) }
        }
    }

    /// Only the daily and the weekly advice (no answers to questions, no per-meal tips); no card when there is none.
    @ViewBuilder private func coach(_ m: DashboardMath) -> some View {
        let a = m.s.advice
        let items = ((a?.today ?? []) + (a?.week.map { [$0] } ?? [])).filter { $0.kind == "day" || $0.kind == "week" }
        if !items.isEmpty {
            Card(title: "Coach", subtitle: nil) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, i in adviceView(i) }
            }
        }
    }

    private func adviceView(_ i: DashboardSnapshot.AdviceItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Chip(text: i.kind == "week" ? "Weekly review" : i.kind == "day" ? "Daily advice" : (i.kind ?? "Advice").capitalized)
                if let ts = i.ts { Text(Date(timeIntervalSince1970: ts).formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                if i.usedLlm == false { Text("· basic tips").font(.caption).foregroundStyle(.secondary) }
            }
            if let h = i.headline { Text(h).font(.subheadline.weight(.semibold)) }
            if let t = i.text { Text(t).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func today(_ m: DashboardMath) -> some View {
        let meals = m.todayMeals, t = m.todayTotals(), plan = m.s.nutrition?.kcal
        let sub = meals.isEmpty ? nil :
            "\(Int(t.kcal.rounded()))\(plan.map { " / \(Int($0))" } ?? "") kcal saved · P \(Int(t.protein.rounded())) g · C \(Int(t.carbs.rounded())) g · F \(Int(t.fat.rounded())) g"
        return Card(title: "Today's nutrition", subtitle: sub) {
            let ind = m.indicators()
            if ind.isEmpty {
                Text("Set your height and goal on the Mac to get a daily plan.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(ind) { IndicatorRow(i: $0) }
            let tiles = m.indices()
            if !tiles.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(tiles) { TileView(t: $0) }
                }
            }
            if meals.isEmpty {
                Text("No meals today. Send a photo of your meal to the Telegram bot.").font(.footnote).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(meals.reversed().enumerated()), id: \.offset) { n, meal in
                        if n > 0 { Divider() }
                        MealRow(meal: meal).padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private func stand(_ m: DashboardMath) -> some View {
        let gs = m.gauges()
        return Card(title: "Where you stand",
                    subtitle: m.latest.map { "Latest reading · \($0.date.formatted(date: .abbreviated, time: .shortened)). Body fat, water and FFMI are formula estimates." }) {
            if gs.isEmpty {
                Text("Add your height in Settings on the Mac and take a measurement to see your position on each scale.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(gs.enumerated()), id: \.offset) { n, g in
                if n > 0 { Divider() }
                RangeGauge(g: g)
            }
        }
    }

    private func goals(_ m: DashboardMath) -> some View {
        let rows = m.goals()
        return Card(title: "Goals", subtitle: "Progress and projection from your recent trend") {
            if let n = m.goalNote() { Text(n).font(.footnote).foregroundStyle(.secondary) }
            if rows.isEmpty { Text("Goals appear after your first reading and your height.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(Array(rows.enumerated()), id: \.offset) { n, r in
                if n > 0 { Divider() }
                GoalRowView(r: r)
            }
        }
    }
}

// MARK: - rows and tiles

private struct KPICard: View {
    let k: DashboardMath.KPI

    private func deltaColor(_ d: Double?) -> Color {
        guard let d, abs(d) >= 0.005 else { return .secondary }
        return d * k.goodDirection > 0 ? Theme.good : Theme.zone("z6")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(k.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if let z = k.zone { Chip(text: z.label, color: Theme.zone(z.cls)) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Fmt.num(k.value, k.decimals)).font(.title2.weight(.bold)).monospacedDigit()
                if !k.unit.isEmpty { Text(k.unit).font(.caption).foregroundStyle(.secondary) }
            }
            if let d = k.deltaSinceLast {
                Text("\(Fmt.signed(d, k.decimals)) since last").font(.caption2).foregroundStyle(deltaColor(d))
            }
            if let a = k.deltaVsAverage {
                Text("\(Fmt.signed(a, k.decimals)) vs 7-day avg").font(.caption2).foregroundStyle(deltaColor(a))
            }
            if let t = k.targetText {
                Text("🎯 \(t)").font(.caption2).foregroundStyle(k.targetReached ? Theme.good : .secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Sparkline(values: k.spark, color: k.zone.map { Theme.zone($0.cls) } ?? Theme.accent)
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) {
            if let z = k.zone { Capsule().fill(Theme.zone(z.cls)).frame(width: 3).padding(.vertical, 14) }
        }
    }
}

private struct IndicatorRow: View {
    let i: DashboardMath.Indicator
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(i.name).font(.subheadline.weight(.semibold))
                Spacer()
                Text(i.word).font(.caption.weight(.semibold)).foregroundStyle(Theme.state(i.state))
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(i.value.rounded()))").font(.title3.weight(.bold)).monospacedDigit()
                Text("/ \(Int(i.target.rounded())) \(i.unit)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(i.detail).font(.caption).foregroundStyle(.secondary)
            }
            ProgressTrack(value: i.progress, color: Theme.state(i.state))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TileView: View {
    let t: DashboardMath.Tile
    private let macroColors: [Color] = [Color(hex: 0x5AA9F5), Color(hex: 0xF5A623), Color(hex: 0xE5484D)]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t.title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(t.value).font(.headline).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                Text(t.unit).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if let split = t.split {
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(Array(split.enumerated()), id: \.offset) { n, p in
                            Rectangle().fill(macroColors[n % 3]).frame(width: geo.size.width * CGFloat(p / 100))
                        }
                    }
                }
                .frame(height: 6).clipShape(Capsule())
            }
            Text(t.word).font(.caption2.weight(.semibold)).foregroundStyle(Theme.state(t.state))
            Text(t.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(10).frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct MealRow: View {
    let meal: DashboardSnapshot.Meal
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(meal.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label).font(.subheadline.weight(.semibold))
                    if meal.status == "pending" { Chip(text: "Pending", color: Theme.zone("z4")) }
                }
                if let items = meal.items, !items.isEmpty {
                    Text(items.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Text("\(Int((meal.kcal ?? 0).rounded())) kcal").font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }
    private var label: String {
        guard let t = meal.type, t != "unknown", !t.isEmpty else { return "Meal" }
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}

private struct GoalRowView: View {
    let r: DashboardMath.GoalRow
    private var color: Color { r.status == .onTrack || r.status == .reached ? Theme.good : r.status == .offTrack ? Theme.zone("z5") : .secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(r.title).font(.subheadline.weight(.semibold))
                if r.isOptimal { Chip(text: "optimal") }
                Spacer()
                Chip(text: r.status.label, color: color)
            }
            Text(r.summary).font(.footnote).foregroundStyle(.secondary)
            ProgressTrack(value: r.progress, color: color)
            HStack(alignment: .top, spacing: 16) {
                fact("Pace", r.weeklyPace.map { "\(Fmt.signed($0, 2)) \(r.unit)/wk" } ?? "—")
                fact("ETA", r.status == .reached ? "Reached" : r.eta.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
            }
            fact("Outlook", r.outlook)
            if let n = r.needPerWeek, let d = r.targetDate { fact("Need for \(d)", "\(Fmt.signed(n, 2)) \(r.unit)/wk") }
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.footnote.weight(.semibold))
        }
    }
}
