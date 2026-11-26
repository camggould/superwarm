import AppKit
import SwiftUI
import SuperwarmCore

/// Earthy design tokens: warm paper and soil surfaces, bark-toned inks,
/// moss and clay accents. Every color has its own light and dark step.
enum Theme {
    static func dynamic(light: UInt32, dark: UInt32, opacity: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: opacity
            )
        })
    }

    // MARK: Surfaces
    static let paperTop = dynamic(light: 0xF7F2E8, dark: 0x1F1C18)
    static let paperBottom = dynamic(light: 0xEFE7D8, dark: 0x171512)
    static let card = dynamic(light: 0xFBF8F2, dark: 0x262320)
    static let cardRaised = dynamic(light: 0xFFFFFF, dark: 0x2E2A26)
    static let hairline = dynamic(light: 0x2B2620, dark: 0xEDE6DB, opacity: 0.09)
    static let track = dynamic(light: 0x2B2620, dark: 0xEDE6DB, opacity: 0.07)

    // MARK: Inks (text always uses these, never a series color)
    static let ink = dynamic(light: 0x2B2620, dark: 0xEDE6DB)
    static let inkSecondary = dynamic(light: 0x6E655A, dark: 0xA89F92)
    static let inkTertiary = dynamic(light: 0x9A9084, dark: 0x7D756B)

    // MARK: Accents
    static let moss = dynamic(light: 0x4F6F3A, dark: 0x9CBF84)
    static let mossWash = dynamic(light: 0x4F6F3A, dark: 0x9CBF84, opacity: 0.12)
    static let clay = dynamic(light: 0xB4532A, dark: 0xE08A5E)
    static let clayWash = dynamic(light: 0xB4532A, dark: 0xE08A5E, opacity: 0.12)
    static let sage = dynamic(light: 0x7C8B6F, dark: 0xA3B196)
    static let sageWash = dynamic(light: 0x7C8B6F, dark: 0xA3B196, opacity: 0.16)

    static let logoTile = LinearGradient(
        colors: [Color(red: 0.80, green: 0.42, blue: 0.20), Color(red: 0.56, green: 0.25, blue: 0.10)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // MARK: Chart series
    // Categorical slots validated with the data-viz palette checker against the
    // card surface (#FBF8F2 light / #262320 dark): lightness band, chroma floor,
    // CVD ΔE ≥ 19, normal-vision ΔE ≥ 24, contrast ≥ 3:1.
    static let lake = dynamic(light: 0x2B6CA3, dark: 0x4A90D0)
    static let ochreClay = dynamic(light: 0xC2682A, dark: 0xD47F3D)

    /// Fixed by entity, never by rank.
    static func color(for provider: Provider) -> Color {
        switch provider {
        case .claudeCode: lake
        case .codex: ochreClay
        }
    }

    // MARK: Type
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .serif) }
    static let title = Font.system(size: 15, weight: .semibold, design: .serif)
    static let eyebrow = Font.system(size: 10.5, weight: .semibold).width(.expanded)
}

struct CardStyle: ViewModifier {
    var fill: Color = Theme.card

    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
    }
}

extension View {
    func card(fill: Color = Theme.card) -> some View { modifier(CardStyle(fill: fill)) }
}

/// Small spaced-out uppercase section label.
struct Eyebrow: View {
    let text: String
    var trailing: String?

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(text.uppercased()).tracking(0.8)
            Spacer()
            if let trailing { Text(trailing) }
        }
        .font(Theme.eyebrow)
        .foregroundStyle(Theme.inkTertiary)
    }
}
