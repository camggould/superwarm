import Foundation

/// An everyday activity to compare an emissions total against.
public struct Equivalent: Sendable, Identifiable, Hashable {
    public let id: String
    public let symbol: String  // SF Symbol name
    public let singular: String
    public let plural: String
    public let gramsPerUnit: Double
    public let citation: Citation
    public let note: String

    /// How many of this activity `grams` of CO2e is equal to.
    public func units(for grams: Double) -> Double { grams / gramsPerUnit }

    public func phrase(for grams: Double) -> String {
        let n = units(for: grams)
        return "\(Format.count(n)) \(abs(n - 1) < 0.05 ? singular : plural)"
    }
}

public struct EquivalentSettings: Codable, Sendable, Hashable {
    /// One-way commute distance in miles.
    public var commuteMilesOneWay: Double

    public init(commuteMilesOneWay: Double = 11.7) {
        self.commuteMilesOneWay = commuteMilesOneWay
    }
}

public enum Equivalents {
    public static let gramsPerCarMile = 400.0
    /// Average US home electricity use, EIA (2022): 10,791 kWh / year.
    public static let homeKWhPerDay = 10_791.0 / 365.25
    public static let gramsPerGallonGasoline = 8_887.0

    /// Equivalents whose size depends on the grid and commute settings.
    public static func all(grid: GridSettings, settings: EquivalentSettings) -> [Equivalent] {
        let gPerWh = grid.gramsCO2PerKWh / 1000
        let commuteGrams = settings.commuteMilesOneWay * 2 * gramsPerCarMile
        return [
            Equivalent(
                id: "car-mile", symbol: "car.fill", singular: "mile driven", plural: "miles driven",
                gramsPerUnit: gramsPerCarMile, citation: Citations.epaVehicle,
                note: "Average US gasoline passenger car."
            ),
            Equivalent(
                id: "commute", symbol: "car.2.fill", singular: "round-trip commute", plural: "round-trip commutes",
                gramsPerUnit: commuteGrams, citation: Citations.nhts,
                note: "\(Format.count(settings.commuteMilesOneWay)) mi each way by car at 400 g/mi."
            ),
            Equivalent(
                id: "kettle", symbol: "cup.and.saucer.fill", singular: "kettle boil", plural: "kettle boils",
                gramsPerUnit: 100 * gPerWh, citation: Citations.egrid,
                note: "1 L heated by 80 °C ≈ 0.1 kWh, on your selected grid."
            ),
            Equivalent(
                id: "home-hour", symbol: "house.fill", singular: "hour of home electricity", plural: "hours of home electricity",
                gramsPerUnit: homeKWhPerDay / 24 * grid.gramsCO2PerKWh, citation: Citations.eiaHome,
                note: "Average US home, ~1.2 kWh per hour, on your selected grid."
            ),
            Equivalent(
                id: "home-day", symbol: "house.fill", singular: "day of home electricity", plural: "days of home electricity",
                gramsPerUnit: homeKWhPerDay * grid.gramsCO2PerKWh, citation: Citations.eiaHome,
                note: "Average US home, ~29.6 kWh per day, on your selected grid."
            ),
            Equivalent(
                id: "phone", symbol: "iphone.gen3", singular: "phone charge", plural: "phone charges",
                gramsPerUnit: 20 * gPerWh, citation: Citations.egrid,
                note: "~15 Wh battery at ~75% charger efficiency ≈ 20 Wh, on your selected grid."
            ),
            Equivalent(
                id: "streaming", symbol: "play.tv.fill", singular: "hour of video streaming", plural: "hours of video streaming",
                gramsPerUnit: 36, citation: Citations.ieaStreaming,
                note: "Device, network and data centre, 2019 global average."
            ),
            Equivalent(
                id: "flight-km", symbol: "airplane", singular: "km flown (short-haul)", plural: "km flown (short-haul)",
                gramsPerUnit: 151, citation: Citations.owidTransport,
                note: "Per passenger, including non-CO2 warming effects."
            ),
            Equivalent(
                id: "gasoline", symbol: "fuelpump.fill", singular: "gallon of gasoline", plural: "gallons of gasoline",
                gramsPerUnit: gramsPerGallonGasoline, citation: Citations.epaVehicle,
                note: "CO2 from burning one US gallon."
            ),
            Equivalent(
                id: "burger", symbol: "fork.knife", singular: "quarter-pound beef burger", plural: "quarter-pound beef burgers",
                gramsPerUnit: 0.1134 * 99_500, citation: Citations.owidFood,
                note: "113 g of beef-herd beef at ~99.5 kg CO2e/kg."
            ),
            Equivalent(
                id: "us-day", symbol: "person.fill", singular: "day of an average American's emissions",
                plural: "days of an average American's emissions",
                gramsPerUnit: 14_300_000 / 365.25, citation: Citations.owidPerCapita,
                note: "~14.3 t fossil CO2 per person per year."
            ),
            Equivalent(
                id: "tree", symbol: "tree.fill", singular: "tree-decade of absorption", plural: "tree-decades of absorption",
                gramsPerUnit: 60_000, citation: Citations.epaEquivalencies,
                note: "CO2 one urban tree seedling takes up over 10 years."
            ),
            Equivalent(
                id: "gemini-prompt", symbol: "sparkles", singular: "median Gemini prompt", plural: "median Gemini prompts",
                gramsPerUnit: 0.03, citation: Citations.googleGemini,
                note: "Google's measured median text prompt, May 2025. A short chat prompt, not an agentic coding turn."
            ),
        ]
    }

    /// The three headline comparisons, one per domain so they don't repeat each
    /// other: getting around (your commute), food (a beef burger) and home energy
    /// (your home's electricity, in hours or days, whichever reads better).
    public static func headline(for grams: Double, grid: GridSettings, settings: EquivalentSettings) -> [Equivalent] {
        let all = all(grid: grid, settings: settings)
        func pick(_ id: String) -> Equivalent { all.first { $0.id == id }! }
        let home = pick("home-day").units(for: grams) >= 1 ? pick("home-day") : pick("home-hour")
        return [pick("commute"), pick("burger"), home]
    }

    /// Picks the comparisons that read most naturally for a given amount:
    /// prefers a unit count between 0.5 and 500, always includes the commute.
    public static func highlights(for grams: Double, grid: GridSettings, settings: EquivalentSettings, limit: Int = 4) -> [Equivalent] {
        let candidates = all(grid: grid, settings: settings)
        guard grams > 0 else { return Array(candidates.prefix(limit)) }
        func score(_ e: Equivalent) -> Double {
            let n = e.units(for: grams)
            if n >= 0.5 && n <= 500 { return abs(log10(n) - 1) }  // sweet spot around 10
            return 10 + abs(log10(max(n, 1e-9)))
        }
        let commute = candidates.first { $0.id == "commute" }!
        let rest = candidates.filter { $0.id != "commute" }.sorted { score($0) < score($1) }
        return [commute] + rest.prefix(limit - 1)
    }
}
