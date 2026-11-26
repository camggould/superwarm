import Foundation

public enum Format {
    /// Three significant figures, trailing zeros dropped: "0.42 g", "12.3 g", "1.2 kg", "267 kg", "3.1 t".
    public static func grams(_ g: Double) -> String {
        let a = abs(g)
        if a >= 1_000_000 { return "\(significant(g / 1_000_000)) t" }
        if a >= 1_000 { return "\(significant(g / 1_000)) kg" }
        if a >= 0.01 || a == 0 { return "\(significant(g)) g" }
        return String(format: "%.1e g", g)
    }

    /// "0.42 Wh", "12.3 Wh", "1.24 kWh", "3.1 MWh".
    public static func energy(wh: Double) -> String {
        let a = abs(wh)
        if a >= 1_000_000 { return "\(significant(wh / 1_000_000)) MWh" }
        if a >= 1_000 { return "\(significant(wh / 1_000)) kWh" }
        return "\(significant(wh)) Wh"
    }

    /// Up to three significant figures (two decimals at most), trailing zeros removed.
    static func significant(_ v: Double) -> String {
        let a = abs(v)
        let decimals = a >= 100 ? 0 : a >= 10 ? 1 : 2
        var text = String(format: "%.\(decimals)f", v)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    /// Short count: "0.3", "4.2", "37", "1.2k", "3.4M".
    public static func count(_ n: Double) -> String {
        let a = abs(n)
        if a >= 1_000_000_000 { return String(format: "%.1fB", n / 1_000_000_000) }
        if a >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if a >= 10_000 { return String(format: "%.1fk", n / 1_000) }
        if a >= 100 { return String(format: "%.0f", n) }
        if a >= 10 { return String(format: "%.0f", n) }
        if a >= 0.1 { return String(format: "%.1f", n) }
        if a == 0 { return "0" }
        return String(format: "%.2f", n)
    }

    public static func tokens(_ n: Int) -> String { count(Double(n)) }
}
