import SwiftUI

/// The AtomHealth identity: the teal-to-indigo gradient and the app-icon mark (an electron orbit with a heartbeat through
/// the nucleus), drawn as vectors so it stays sharp at any size and needs no image asset. Matches `static/assets/icon.svg`.
enum Brand {
    static let teal = Color(hex: 0x14B8A6)
    static let indigo = Color(hex: 0x4338CA)
    static let gradient = LinearGradient(colors: [teal, indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let name = "AtomHealth"
}

/// The icon as a view: a rounded gradient tile with the orbit, the electron and the heartbeat line.
struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        Canvas { ctx, sz in
            let k = sz.width / 512
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: sz), cornerRadius: 112 * k, style: .continuous),
                     with: .linearGradient(Gradient(colors: [Brand.teal, Brand.indigo]), startPoint: .zero, endPoint: CGPoint(x: sz.width, y: sz.height)))
            var orbit = ctx
            orbit.translateBy(x: 256 * k, y: 256 * k); orbit.rotate(by: .degrees(-28))
            orbit.stroke(Path(ellipseIn: CGRect(x: -178 * k, y: -82 * k, width: 356 * k, height: 164 * k)),
                         with: .color(.white.opacity(0.55)), lineWidth: 20 * k)
            ctx.fill(Path(ellipseIn: CGRect(x: (301 - 27) * k, y: (152 - 27) * k, width: 54 * k, height: 54 * k)), with: .color(.white))
            var beat = Path()
            beat.move(to: pt(92, 278)); beat.addLine(to: pt(192, 278)); beat.addLine(to: pt(224, 204))
            beat.addLine(to: pt(268, 344)); beat.addLine(to: pt(302, 256)); beat.addLine(to: pt(420, 256))
            ctx.stroke(beat, with: .color(.white), style: StrokeStyle(lineWidth: 28 * k, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("AtomHealth")
    }
}

/// Mark + two-tone wordmark ("Atom" bold, "Health" lighter), as on the Mac dashboard's header.
struct BrandLockup: View {
    var markSize: CGFloat = 30
    var font: Font = .headline

    var body: some View {
        HStack(spacing: 8) {
            BrandMark(size: markSize)
            (Text("Atom").fontWeight(.bold) + Text("Health").fontWeight(.regular).foregroundStyle(.secondary)).font(font)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("AtomHealth")
    }
}

extension View {
    /// Puts the brand mark at the leading edge of a large-title navigation bar (Overview, Sync).
    func brandedToolbar() -> some View {
        toolbar { ToolbarItem(placement: .topBarLeading) { BrandMark(size: 28) } }
    }
}
