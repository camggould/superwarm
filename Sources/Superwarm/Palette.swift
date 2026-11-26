import AppKit
import SwiftUI
import SuperwarmCore

/// Chart colors. Validated categorical slots 1-2 of the reference data-viz
/// palette, each with its own light and dark step.
enum Palette {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Slot 1, blue.
    static let series1 = dynamic(light: hex(0x257DE0), dark: hex(0x338CED))
    /// Slot 2, orange.
    static let series2 = dynamic(light: hex(0xF47230), dark: hex(0xE76624))

    /// Fixed by entity, never by rank: Claude Code is always slot 1.
    static func color(for provider: Provider) -> Color {
        switch provider {
        case .claudeCode: series1
        case .codex: series2
        }
    }

    /// Brand warmth for non-data accents (hero number, efficiency card).
    static let ember = dynamic(light: hex(0xC2410C), dark: hex(0xFB923C))
    static let leaf = dynamic(light: hex(0x15803D), dark: hex(0x4ADE80))
}
