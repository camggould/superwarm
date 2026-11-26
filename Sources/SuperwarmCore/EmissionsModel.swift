import Foundation

/// A best estimate with an approximate 90% interval.
public struct Interval: Codable, Sendable, Hashable {
    public var low: Double
    public var central: Double
    public var high: Double

    public init(low: Double, central: Double, high: Double) {
        self.low = low
        self.central = central
        self.high = high
    }

    public static let zero = Interval(low: 0, central: 0, high: 0)

    /// Intervals are summed bound-by-bound. The same coefficients apply to every
    /// record, so the errors are fully correlated and do not shrink as records add up.
    public static func + (a: Interval, b: Interval) -> Interval {
        Interval(low: a.low + b.low, central: a.central + b.central, high: a.high + b.high)
    }

    public static func += (a: inout Interval, b: Interval) { a = a + b }

    public static func * (a: Interval, k: Double) -> Interval {
        Interval(low: a.low * k, central: a.central * k, high: a.high * k)
    }
}

/// A coefficient with a central value and a multiplicative uncertainty `spread`:
/// the 90% interval is `central / spread ... central * spread`.
public struct Coefficient: Codable, Sendable, Hashable {
    public var central: Double
    public var spread: Double

    public init(_ central: Double, spread: Double) {
        self.central = central
        self.spread = spread
    }

    var logSpread: Double { log(spread) }
}

/// The physical model. Every default here is derived in docs/METHODOLOGY.md.
public struct EnergyCoefficients: Codable, Sendable, Hashable {
    /// IT energy (accelerators + host + idle fleet capacity, before PUE), in Wh
    /// per 1,000 output tokens, for a large frontier model of the reference generation.
    public var baseWhPer1kOutput = Coefficient(0.9, spread: 2.8)

    /// Energy per token relative to a large model.
    public var tierMultiplier: [ModelTier: Coefficient] = [
        .large: Coefficient(1.0, spread: 1.0),
        .medium: Coefficient(0.45, spread: 1.8),
        .small: Coefficient(0.12, spread: 2.2),
        .unknown: Coefficient(0.45, spread: 3.0),
    ]

    /// Energy of one uncached input (prefill) token relative to one output (decode) token.
    public var inputToOutputRatio = Coefficient(0.2, spread: 2.0)
    /// Energy of a prompt-cache read relative to an uncached input token.
    public var cacheReadToInputRatio = Coefficient(0.1, spread: 2.5)
    /// Energy of a prompt-cache write relative to an uncached input token.
    public var cacheWriteToInputRatio = Coefficient(1.0, spread: 1.3)

    /// Multiplicative change in energy per token for each year a model generation
    /// is newer than `referenceGeneration`. The 0.6 default is a 1.67x yearly gain.
    public var annualEfficiencyFactor = Coefficient(0.6, spread: 1.6)

    /// The generation the baseline is calibrated against (GPT-4o / Claude 3.5 era, mid-2024).
    public var referenceGeneration = Date(timeIntervalSince1970: 1_719_792_000)  // 2024-07-01

    /// Trend extrapolation is clamped to this many years either side of the reference.
    public var maxTrendYears = 4.0

    public init() {}
}

/// User-adjustable assumptions about where inference runs.
public struct GridSettings: Codable, Sendable, Hashable {
    /// Grams of CO2e per kWh of electricity drawn by the data centre.
    public var gramsCO2PerKWh: Double
    /// Power Usage Effectiveness: facility energy / IT energy.
    public var pue: Double

    public init(gramsCO2PerKWh: Double = GridPreset.usAverage.gramsCO2PerKWh, pue: Double = 1.15) {
        self.gramsCO2PerKWh = gramsCO2PerKWh
        self.pue = pue
    }
}

public enum GridPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case usAverage, worldAverage, lowCarbon, custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .usAverage: "US average grid (EPA eGRID)"
        case .worldAverage: "World average grid (Ember)"
        case .lowCarbon: "Low-carbon grid (hydro/nuclear-heavy)"
        case .custom: "Custom"
        }
    }

    public var gramsCO2PerKWh: Double {
        switch self {
        case .usAverage: 373
        case .worldAverage: 473
        case .lowCarbon: 50
        case .custom: 373
        }
    }
}

/// Energy and carbon for one record or an aggregate.
public struct Footprint: Codable, Sendable, Hashable {
    /// Facility-level energy (Wh), including PUE.
    public var energyWh: Interval
    public var co2Grams: Interval
    /// Central CO2 if the same tokens had run on a reference-generation (2024) model of the same tier.
    public var baselineCO2Grams: Double

    public static let zero = Footprint(energyWh: .zero, co2Grams: .zero, baselineCO2Grams: 0)

    public static func + (a: Footprint, b: Footprint) -> Footprint {
        Footprint(energyWh: a.energyWh + b.energyWh,
                  co2Grams: a.co2Grams + b.co2Grams,
                  baselineCO2Grams: a.baselineCO2Grams + b.baselineCO2Grams)
    }

    public static func += (a: inout Footprint, b: Footprint) { a = a + b }

    /// CO2 avoided compared with running the same work on 2024-era models.
    public var efficiencyDividendGrams: Double { baselineCO2Grams - co2Grams.central }
}

public struct EmissionsModel: Sendable {
    public var coefficients: EnergyCoefficients
    public var grid: GridSettings

    public init(coefficients: EnergyCoefficients = EnergyCoefficients(), grid: GridSettings = GridSettings()) {
        self.coefficients = coefficients
        self.grid = grid
    }

    static let secondsPerYear = 365.25 * 86_400

    public func yearsFromReference(_ generation: Date) -> Double {
        let years = generation.timeIntervalSince(coefficients.referenceGeneration) / Self.secondsPerYear
        return min(max(years, -coefficients.maxTrendYears), coefficients.maxTrendYears)
    }

    public func footprint(tokens: TokenCounts, profile: ModelProfile) -> Footprint {
        let c = coefficients
        let tier = c.tierMultiplier[profile.tier] ?? c.tierMultiplier[.unknown]!

        // Convert everything to "output-token equivalents".
        let inputEq = c.inputToOutputRatio.central
        let cacheReadEq = inputEq * c.cacheReadToInputRatio.central
        let cacheWriteEq = inputEq * c.cacheWriteToInputRatio.central
        let output = Double(tokens.output)
        let input = Double(tokens.input) * inputEq
        let cacheRead = Double(tokens.cacheRead) * cacheReadEq
        let cacheWrite = Double(tokens.cacheWrite) * cacheWriteEq
        let outputEquivalents = output + input + cacheRead + cacheWrite
        guard outputEquivalents > 0 else { return .zero }

        let years = yearsFromReference(profile.generation)
        let trend = pow(c.annualEfficiencyFactor.central, years)
        let perToken = c.baseWhPer1kOutput.central / 1000 * tier.central
        let itWh = outputEquivalents * perToken * trend
        let baselineItWh = outputEquivalents * perToken
        let facilityWh = itWh * grid.pue

        // Combine independent log-normal uncertainties. Input-side ratios only
        // affect their share of the energy, so they are weighted by it.
        let inputShare = (input + cacheRead + cacheWrite) / outputEquivalents
        let cacheReadShare = cacheRead / outputEquivalents
        let cacheWriteShare = cacheWrite / outputEquivalents
        let variance =
            pow(c.baseWhPer1kOutput.logSpread, 2)
            + pow(tier.logSpread, 2)
            + pow(inputShare * c.inputToOutputRatio.logSpread, 2)
            + pow(cacheReadShare * c.cacheReadToInputRatio.logSpread, 2)
            + pow(cacheWriteShare * c.cacheWriteToInputRatio.logSpread, 2)
            + pow(abs(years) * c.annualEfficiencyFactor.logSpread, 2)
        let spread = exp(variance.squareRoot())

        let energy = Interval(low: facilityWh / spread, central: facilityWh, high: facilityWh * spread)
        let gramsPerWh = grid.gramsCO2PerKWh / 1000
        return Footprint(
            energyWh: energy,
            co2Grams: energy * gramsPerWh,
            baselineCO2Grams: baselineItWh * grid.pue * gramsPerWh
        )
    }
}
