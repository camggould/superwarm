import AppKit
import SwiftUI
import SuperwarmKit

/// Earthy accent colors on native surfaces. Every color has its own light and dark step.
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

    // MARK: Accents (icons and small highlights only; text uses system inks)
    static let moss = dynamic(light: 0x4F6F3A, dark: 0x9CBF84)
    static let clay = dynamic(light: 0xB4532A, dark: 0xE08A5E)

    // MARK: Chart series
    // Categorical slots validated with the data-viz palette checker against the
    // native popover surface (#ECECEC light / #323232 dark): lightness band,
    // chroma floor, CVD ΔE ≥ 19, normal-vision ΔE ≥ 25, contrast ≥ 3:1.
    static let lake = dynamic(light: 0x2B6CA3, dark: 0x4A90D0)
    static let ochreClay = dynamic(light: 0xC2682A, dark: 0xD47F3D)

    /// Fixed by entity, never by rank.
    static func color(for provider: Provider) -> Color {
        switch provider {
        case .claudeCode: lake
        case .codex: ochreClay
        }
    }
}
