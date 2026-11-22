import AtomHealthCore
import Charts
import SwiftUI

/// The Apple Health side of the Overview: the trend chart, today's rings and the key-indicator tiles.
enum HealthPalette {
    static let steps = Color(hex: 0x5AA9F5), active = Color(hex: 0xF2375A), exercise = Color(hex: 0x22B573)
    static func color(_ m: HealthMath.Metric) -> Color {
        switch m {
        case .weight: Theme.accent
        case .fat: Color(hex: 0xF5A623)
        case .steps: steps
        case .active: active
        case .exercise: exercise
        case .sleep: Color(hex: 0x7C3AED)
        case .restingHR: Color(hex: 0xE5484D)
        case .hrv: Color(hex: 0x0EA5A4)
        }
    }
}

// MARK: - trend chart

/// One chart with a metric picker (weight, body fat, steps, energy, exercise, sleep, resting heart rate, HRV) and a range.
struct TrendCard: View {
    let m: HealthMath
    @State private var metric: HealthMath.Metric = .weight
    @State private var days = 14

    var body: some View {
        let avail = m.availableMetrics()
        let cur = avail.contains(metric) ? metric : (avail.first ?? .weight)
        let t = m.trend(cur, days: days)
        let color = HealthPalette.color(cur)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                chips(avail, selected: cur)
                header(t, color: color)
                if t.points.isEmpty {
                    Text("No \(cur.title.lowercased()) data in this period.").font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    chart(t, color: color).frame(height: 170)
                }
                Picker("Range", selection: $days) {
                    Text("7 days").tag(7); Text("14 days").tag(14); Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func chips(_ avail: [HealthMath.Metric], selected: HealthMath.Metric) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(avail) { k in
                    Button { metric = k } label: {
                        Text(k.title).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .foregroundStyle(k == selected ? Color.white : Color.primary)
                            .background(k == selected ? HealthPalette.color(k) : Color.primary.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(k == selected ? .isSelected : [])
                }
            }
        }
    }

    private func header(_ t: HealthMath.Trend, color: Color) -> some View {
        let k = t.metric
        let big = k.isBars ? t.average : t.latest
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(big.map { k.decimals == 0 ? Fmt.thousands($0) : Fmt.num($0, k.decimals) } ?? "—")
                        .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(k.isBars ? "\(k.unit)\(k.unit.isEmpty ? "" : " ")avg per day" : k.unit).font(.subheadline).foregroundStyle(.secondary)
                }
                if let c = t.change {
                    Text("\(Fmt.signed(c, k.decimals)) \(k.unit) over \(days) days").font(.caption.weight(.semibold))
                        .foregroundStyle(changeColor(k, c))
                } else if let g = t.goalLabel {
                    Text(g).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    /// Weight and body fat are good going down; heart rate too; the rest are good going up.
    private func changeColor(_ k: HealthMath.Metric, _ c: Double) -> Color {
        guard abs(c) > 0.0001 else { return .secondary }
        let downIsGood = k == .weight || k == .fat || k == .restingHR
        return (c < 0) == downIsGood ? Theme.good : Theme.zone("z4")
    }

    @ChartContentBuilder private func marks(_ t: HealthMath.Trend, color: Color) -> some ChartContent {
        ForEach(t.points) { p in
            if t.metric.isBars {
                BarMark(x: .value("Day", p.date, unit: .day), y: .value(t.metric.title, p.value))
                    .foregroundStyle(color.gradient).cornerRadius(3)
            } else {
                AreaMark(x: .value("Day", p.date), y: .value(t.metric.title, p.value))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.28), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", p.date), y: .value(t.metric.title, p.value))
                    .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round)).interpolationMethod(.monotone)
                if t.points.count <= 20 {
                    PointMark(x: .value("Day", p.date), y: .value(t.metric.title, p.value)).foregroundStyle(color).symbolSize(26)
                }
            }
        }
        if let g = t.goal {
            RuleMark(y: .value("Goal", g)).lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4])).foregroundStyle(Color.secondary)
                .annotation(position: .top, alignment: .trailing, spacing: 2) {
                    if let l = t.goalLabel { Text(l).font(.caption2).foregroundStyle(.secondary) }
                }
        }
    }

    private func chart(_ t: HealthMath.Trend, color: Color) -> some View {
        let values = t.points.map(\.value) + (t.goal.map { [$0] } ?? [])
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let pad = Swift.max((hi - lo) * 0.12, t.metric == .weight ? 0.5 : 1)
        return Chart { marks(t, color: color) }
            .chartYScale(domain: (t.metric.isBars ? 0 : lo - pad) ... (hi + pad))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine(); AxisValueLabel() } }
    }
}

// MARK: - rings

/// Today's steps, active energy and exercise against their goals.
struct RingsCard: View {
    let m: HealthMath
    var body: some View {
        Card(title: "Today", subtitle: "From Apple Health · goals: 10,000 steps, 500 kcal active, 30 min exercise") {
            HStack(alignment: .top, spacing: 8) {
                ForEach(m.rings()) { r in RingView(r: r) }
            }
        }
    }
}

private struct RingView: View {
    let r: HealthMath.Ring
    private var color: Color { r.id == "steps" ? HealthPalette.steps : r.id == "active" ? HealthPalette.active : HealthPalette.exercise }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: 11)
                Circle().trim(from: 0, to: Swift.min(r.progress, 1)).stroke(color, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if r.progress > 1 {                                    // goal beaten: a second lap in a lighter shade
                    Circle().trim(from: 0, to: Swift.min(r.progress - 1, 1)).stroke(color.opacity(0.55), style: StrokeStyle(lineWidth: 11, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text("\(Int((r.progress * 100).rounded()))%").font(.subheadline.weight(.bold)).monospacedDigit()
            }
            .frame(width: 84, height: 84)
            Text(r.title).font(.caption).foregroundStyle(.secondary)
            Text("\(Fmt.thousands(r.value))\(r.unit.isEmpty ? "" : " \(r.unit)")").font(.footnote.weight(.semibold)).monospacedDigit()
            Text("of \(Fmt.thousands(r.goal))").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(r.title) \(Int(r.value.rounded())) of \(Int(r.goal)), \(Int((r.progress * 100).rounded())) percent")
    }
}

// MARK: - key indicators

struct IndexGrid: View {
    let items: [HealthMath.Index]
    let m: HealthMath
    @State private var showHRV = false
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(items) { i in
                if i.id == "hrv" {
                    Button { showHRV = true } label: { IndexTile(i: i, tappable: true) }.buttonStyle(.plain)
                        .accessibilityHint("Opens the detailed HRV chart")
                } else { IndexTile(i: i) }
            }
        }
        .sheet(isPresented: $showHRV) { HRVDetailView(m: m) }
    }
}

private struct IndexTile: View {
    let i: HealthMath.Index
    var tappable = false
    var body: some View {
        let c = Theme.state(i.state)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(i.title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                if tappable { Spacer(minLength: 0); Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(i.value).font(.title2.weight(.bold)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                Text(i.unit).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(i.word).font(.caption.weight(.semibold)).foregroundStyle(c)
            Text(i.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            if i.spark.count >= 2 { Sparkline(values: i.spark, color: c) }
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) { Capsule().fill(c).frame(width: 3).padding(.vertical, 14) }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - no data

struct HealthEmptyCard: View {
    let busy: Bool
    let refresh: () -> Void
    var body: some View {
        Card(title: "Apple Health", subtitle: "Steps, sleep, heart rate and workouts appear here") {
            Text("No Health data yet. If you have not allowed access, open Settings › Health › Data Access & Devices › AtomHealth and turn on everything. Health data is also unreadable while the phone is locked.")
                .font(.footnote).foregroundStyle(.secondary)
            Button(busy ? "Reading…" : "Read Health now", action: refresh).buttonStyle(.bordered).disabled(busy)
        }
    }
}
