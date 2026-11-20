import AtomHealthCore
import SwiftUI

/// Colours and small building blocks shared by the screens. The zone palette matches the Mac dashboard (`--z1…--z6`).
enum Theme {
    static let accent = Color(light: 0x1D5FC0, dark: 0x5B9BF0)   // brand blue; actions, selection, links
    static let good = Color(hex: 0x22B573)

    static func zone(_ cls: String) -> Color {
        switch cls {
        case "z1": Color(hex: 0x5AA9F5)
        case "z2": good
        case "z3": Color(hex: 0x8BCF3F)
        case "z4": Color(hex: 0xF5A623)
        case "z5": Color(hex: 0xF2762E)
        case "z6": Color(hex: 0xE5484D)
        default: .gray
        }
    }

    static func state(_ s: DashboardMath.NState) -> Color {
        switch s { case .low: zone("z1"); case .ok: good; case .warn: zone("z4"); case .over: zone("z6") }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light)) })
    }
}

/// A rounded surface with an optional title, like the cards on the Mac dashboard.
struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct Chip: View {
    let text: String
    var color: Color = Theme.accent
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// The small trend line under a KPI value.
struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.accent
    var body: some View {
        GeometryReader { geo in
            if values.count >= 2, let lo = values.min(), let hi = values.max() {
                let range = max(hi - lo, 0.0001)
                Path { p in
                    for (i, v) in values.enumerated() {
                        let pt = CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(values.count - 1),
                                         y: geo.size.height * (1 - CGFloat((v - lo) / range)) * 0.9 + geo.size.height * 0.05)
                        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: 22)
    }
}

/// A coloured scale with the current value pinned on it and tick marks for optimal/target values.
struct RangeGauge: View {
    let g: DashboardMath.Gauge

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.name).font(.subheadline.weight(.semibold))
                    if let t = g.target { Text("🎯 \(t)").font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(Fmt.num(g.value, g.decimals)).font(.title3.weight(.bold)).monospacedDigit()
                    if !g.unit.isEmpty { Text(g.unit).font(.caption).foregroundStyle(.secondary) }
                    if let v = g.verdict { Chip(text: v.label, color: Theme.zone(v.cls)) }
                }
            }
            track
            Text(g.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width, span = max(g.max - g.min, 0.0001)
            let x: (Double) -> CGFloat = { CGFloat(Swift.max(0, Swift.min(1, ($0 - g.min) / span))) * w }
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    ForEach(Array(g.zones.enumerated()), id: \.offset) { _, z in
                        Rectangle().fill(Theme.zone(z.cls).opacity(0.85))
                            .frame(width: Swift.max(0, x(z.to) - x(z.from))).offset(x: x(z.from))
                    }
                }
                .frame(width: w, height: 10, alignment: .leading).clipShape(Capsule())
                ForEach(Array(g.refs.enumerated()), id: \.offset) { _, r in
                    Rectangle().fill(.white).frame(width: 2, height: 14).offset(x: x(r.value) - 1)
                }
                Circle().fill(.white).frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.primary.opacity(0.75), lineWidth: 3))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: x(g.value) - 9)
            }
            .frame(height: geo.size.height)
        }
        .frame(height: 20)
    }
}

/// A labelled progress bar (today's nutrition, goals).
struct ProgressTrack: View {
    let value: Double          // 0...1
    var color: Color = Theme.accent
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: geo.size.width * CGFloat(Swift.max(0, Swift.min(1, value))))
            }
        }
        .frame(height: 8)
    }
}
