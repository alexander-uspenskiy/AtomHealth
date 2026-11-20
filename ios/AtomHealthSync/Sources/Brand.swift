import SwiftUI

/// The AtomHealth identity: the blue-to-teal gradient and the app icon (atom with a heart as the nucleus).
enum Brand {
    static let teal = Color(hex: 0x14B8A6)
    static let indigo = Color(hex: 0x2B2A83)
    static let blue = Color(hex: 0x1D5FC0)
    /// Deep indigo to blue to teal, diagonal: the icon's background.
    static let gradient = LinearGradient(colors: [indigo, blue, teal], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let name = "AtomHealth"
}

/// The app icon as a view (the same artwork as the home-screen icon: atom, heart and pulse), clipped like an iOS icon.
struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        Image("BrandIcon").resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
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
    /// Puts the app icon and the AtomHealth name at the leading edge of a large-title navigation bar (Overview, Sync).
    func brandedToolbar() -> some View {
        toolbar { ToolbarItem(placement: .topBarLeading) { BrandLockup(markSize: 26, font: .subheadline) } }
    }
}
