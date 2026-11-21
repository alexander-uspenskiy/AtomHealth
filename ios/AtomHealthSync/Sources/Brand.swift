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
    /// The one navigation bar every main screen (Overview, Chat, Sync) uses: inline title, app icon + name at the leading
    /// edge, grouped-background canvas. Do not give a screen its own bar style.
    /// `back` (Chat while the keyboard hides the tab bar) adds a back chevron and drops the wordmark, leaving the
    /// centre title room: one tidy leading group instead of three crowded items.
    func brandedScreen(title: String, back: (() -> Void)? = nil) -> some View {
        self.background(Color(.systemGroupedBackground))
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let back {
                        HStack(spacing: 4) {
                            Button(action: back) {
                                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                                    .frame(width: 36, height: 36).contentShape(Rectangle())
                            }
                            .accessibilityLabel("Back to Overview")
                            BrandMark(size: 26)
                        }
                    } else { BrandLockup(markSize: 26, font: .subheadline) }
                }
            }
    }
}

/// The gradient banner at the top of a screen (Overview: latest reading, Sync: connection state).
struct BrandHero<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 14)
            .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// A full-width brand-gradient button (primary actions).
struct BrandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .background(Brand.gradient, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
