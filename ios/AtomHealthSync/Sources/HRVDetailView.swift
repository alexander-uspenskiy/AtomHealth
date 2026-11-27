import AtomHealthCore
import Charts
import SwiftUI

/// Heart rate variability in detail: daily values, 7-day rolling average, your personal normal range, and a plain-language
/// explanation. Opened from the HRV tile on the Overview.
struct HRVDetailView: View {
    let m: HealthMath
    @Environment(\.dismiss) private var dismiss
    @State private var days = 30
    private let color = HealthPalette.color(.hrv)

    var body: some View {
        let d = m.hrvDetail(days: days)
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            header(d)
                            if d.points.count < 2 {
                                Text("Not enough HRV readings in this period yet.").font(.footnote).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 200)
                            } else {
                                chart(d).frame(height: 230)
                                legend(d)
                            }
                            Picker("Range", selection: $days) {
                                Text("7 days").tag(7); Text("14 days").tag(14); Text("30 days").tag(30); Text("90 days").tag(90)
                            }.pickerStyle(.segmented)
                        }
                    }
                    stats(d)
                    explanation
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Heart rate variability").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func status(_ d: HealthMath.HRVDetail) -> (String, Color) {
        guard let r = d.ratio else { return ("No baseline yet", .secondary) }
        if r >= 1.05 { return ("Above your baseline", Theme.good) }
        if r >= 0.95 { return ("At your baseline", Theme.good) }
        if r >= 0.8 { return ("Below your baseline", Theme.zone("z4")) }
        return ("Low: go easy today", Theme.zone("z6"))
    }

    private func header(_ d: HealthMath.HRVDetail) -> some View {
        let (word, c) = status(d)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(d.latest.map { Fmt.num($0, 0) } ?? "—").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                Text("ms · latest").font(.subheadline).foregroundStyle(.secondary)
            }
            Chip(text: word, color: c)
        }
    }

    private func chart(_ d: HealthMath.HRVDetail) -> some View {
        let vals = d.points.map(\.value) + [d.normalLow, d.normalHigh].compactMap { $0 }
        let lo = (vals.min() ?? 0), hi = (vals.max() ?? 1)
        let pad = Swift.max((hi - lo) * 0.15, 3)
        let first = d.points.first!.date, last = d.points.last!.date
        return Chart {
            if let l = d.normalLow, let h = d.normalHigh {
                RectangleMark(xStart: .value("From", first), xEnd: .value("To", last), yStart: .value("Low", l), yEnd: .value("High", h))
                    .foregroundStyle(color.opacity(0.12))
            }
            if let b = d.baseline7 {
                RuleMark(y: .value("Baseline", b)).lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4])).foregroundStyle(Color.secondary)
            }
            ForEach(d.points) { p in
                LineMark(x: .value("Day", p.date), y: .value("HRV", p.value), series: .value("S", "daily"))
                    .foregroundStyle(color.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1.5)).interpolationMethod(.monotone)
                PointMark(x: .value("Day", p.date), y: .value("HRV", p.value)).foregroundStyle(color).symbolSize(d.points.count > 40 ? 10 : 28)
            }
            ForEach(d.rolling) { p in
                LineMark(x: .value("Day", p.date), y: .value("HRV", p.value), series: .value("S", "avg"))
                    .foregroundStyle(Theme.accent).lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round)).interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: Swift.max(0, lo - pad) ... (hi + pad))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
        .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine(); AxisValueLabel() } }
    }

    private func legend(_ d: HealthMath.HRVDetail) -> some View {
        HStack(spacing: 14) {
            key(color, "Daily")
            key(Theme.accent, "7-day average")
            if d.normalLow != nil { key(color.opacity(0.3), "Your normal range") }
            if d.baseline7 != nil { key(.secondary, "Baseline") }
        }.font(.caption2).foregroundStyle(.secondary)
    }

    private func key(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 7, height: 7); Text(t) }
    }

    private func stats(_ d: HealthMath.HRVDetail) -> some View {
        Card(title: "This period") {
            HStack(alignment: .top) {
                stat("Average", d.average); stat("Lowest", d.min); stat("Highest", d.max); stat("Baseline", d.baseline7)
            }
        }
    }

    private func stat(_ t: String, _ v: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption2).foregroundStyle(.secondary)
            Text(v.map { "\(Fmt.num($0, 0)) ms" } ?? "—").font(.subheadline.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var explanation: some View {
        Card(title: "What is HRV?") {
            VStack(alignment: .leading, spacing: 10) {
                para("Your heartbeat is not a metronome. The time between beats varies by a few milliseconds, and heart rate variability (HRV) measures how much. Apple Health records it as SDNN, the spread of those gaps, in milliseconds.")
                para("Higher usually means your nervous system is relaxed and recovered; lower means it is under load from hard training, stress, illness, alcohol or short sleep.")
                Divider()
                Text("How to read the chart").font(.subheadline.weight(.semibold))
                para("• Dots are daily averages; the thick line smooths them over 7 readings.\n• The shaded band is your own normal range (average ± 0.75 standard deviations). Inside it is ordinary day-to-day noise.\n• The dashed line is your 7-day baseline, the same one the Overview tile compares against.")
                Text("What matters").font(.subheadline.weight(.semibold))
                para("• Compare with yourself, not other people: HRV differs a lot by age, genetics and device, so 40 ms can be normal for one person and 90 ms for another.\n• Trends beat single days. One low reading is common; several days below the band suggest you need rest.\n• Below 80% of baseline the app says go easy; at or above 95% you are at baseline.\n• Helpers: consistent sleep, easy aerobic exercise, less alcohol, managing stress.")
                Text("Not medical advice. Talk to a doctor about persistent changes or symptoms.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func para(_ s: String) -> some View {
        Text(s).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
