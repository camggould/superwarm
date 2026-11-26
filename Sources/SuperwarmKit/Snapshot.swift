import Foundation

// Decodable mirror of the Rust engine's `superwarm snapshot` JSON
// (engine/src/snapshot.rs). Field names match the engine's camelCase keys.

public enum Provider: String, Codable, Sendable, CaseIterable, Hashable {
    case claudeCode, codex

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

public enum ModelTier: String, Codable, Sendable, CaseIterable {
    case large, medium, small, unknown

    public var displayName: String { rawValue.capitalized }
}

public enum GenerationSource: String, Codable, Sendable {
    case catalog, firstSeen, override
}

/// The periods the popover can show. Raw values are the engine's period ids.
public enum Period: String, Codable, Sendable, CaseIterable, Identifiable {
    case today, week, month, year, allTime

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        case .year: "Year"
        case .allTime: "All time"
        }
    }
}

public enum Bucket: String, Codable, Sendable {
    case hour, day, week, month

    public var calendarComponent: Calendar.Component {
        switch self {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }
}

/// A best estimate with an approximate 90% interval.
public struct Interval: Codable, Sendable, Hashable {
    public var low: Double
    public var central: Double
    public var high: Double
}

public struct Footprint: Codable, Sendable, Hashable {
    /// Facility-level energy (Wh), including PUE.
    public var energyWh: Interval
    public var co2Grams: Interval
    /// Central CO2 if the same tokens had run on 2024-era models of the same size.
    public var baselineCO2Grams: Double

    enum CodingKeys: String, CodingKey {
        case energyWh, co2Grams
        case baselineCO2Grams = "baselineCo2Grams"
    }

    /// CO2 avoided compared with running the same work on 2024-era models.
    public var efficiencyDividendGrams: Double { baselineCO2Grams - co2Grams.central }
}

public struct TokenCounts: Codable, Sendable, Hashable {
    public var input: Int
    public var cacheWrite: Int
    public var cacheRead: Int
    public var output: Int

    public var total: Int { input + cacheWrite + cacheRead + output }
}

public struct Summary: Codable, Sendable, Hashable {
    public var tokens: TokenCounts
    public var footprint: Footprint
    public var responses: Int
}

public struct TimeRange: Codable, Sendable, Hashable {
    public var startMs: Int64
    public var endMs: Int64
}

public struct TimelinePoint: Codable, Sendable, Hashable, Identifiable {
    public var startMs: Int64
    public var provider: Provider
    public var co2Grams: Double
    public var energyWh: Double

    public var start: Date { Date(milliseconds: startMs) }
    public var id: String { "\(startMs)-\(provider.rawValue)" }
}

public struct ModelRow: Codable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var provider: Provider
    public var tier: ModelTier
    public var generationMs: Int64
    public var generationSource: GenerationSource
    public var summary: Summary
    public var gramsPerThousandOutput: Double

    public var generation: Date { Date(milliseconds: generationMs) }
    public var rowID: String { "\(provider.rawValue):\(id)" }
}

public struct PreviousPeriod: Codable, Sendable {
    public var label: String
    public var co2Grams: Double
}

public struct TierTip: Codable, Sendable {
    public var actual: Double
    public var alternative: Double
    /// All large-model work was Claude Opus.
    public var allOpus: Bool
}

/// Usage from one machine: this one, or a remote synced with `superwarm sync`.
public struct MachineRow: Codable, Sendable, Identifiable {
    public var name: String
    public var isLocal: Bool
    public var summary: Summary
    public var id: String { name }
}

/// A remote machine's sync state.
public struct RemoteStatus: Codable, Sendable, Identifiable {
    public var name: String
    /// The ssh target, or nil for machines added with `superwarm import`.
    public var ssh: String?
    public var lastSyncMs: Int64?
    public var lastError: String?
    public var responses: Int
    public var id: String { name }
    public var lastSync: Date? { lastSyncMs.map(Date.init(milliseconds:)) }
}

public struct PeriodSnapshot: Codable, Sendable {
    public var period: Period
    public var label: String
    public var range: TimeRange?
    public var bucket: Bucket
    public var summary: Summary
    public var timeline: [TimelinePoint]
    public var models: [ModelRow]
    /// The same stretch of the previous period, when the logs cover it.
    public var previous: PreviousPeriod?
    /// What the large-model work would emit on mid-size models.
    public var tierTip: TierTip?
    /// Ids of the three headline equivalents.
    public var headline: [String]
    /// Usage per machine, largest first (engine 0.2+).
    public var machines: [MachineRow]?
}

public struct Equivalent: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    /// SF Symbol name.
    public var symbol: String
    public var singular: String
    public var plural: String
    public var gramsPerUnit: Double
    public var citationId: String
    public var note: String

    /// How many of this activity `grams` of CO2e is equal to.
    public func units(for grams: Double) -> Double { grams / gramsPerUnit }

    public func phrase(for grams: Double) -> String {
        let n = units(for: grams)
        return "\(Format.count(n)) \(abs(n - 1) < 0.05 ? singular : plural)"
    }
}

public struct Citation: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var publisher: String
    public var year: Int
    public var url: URL
    public var usedFor: String
}

public struct Coefficient: Codable, Sendable, Hashable {
    public var central: Double
    public var spread: Double
}

public struct EnergyCoefficients: Codable, Sendable, Hashable {
    public var baseWhPer1kOutput: Coefficient
    public var tierLarge: Coefficient
    public var tierMedium: Coefficient
    public var tierSmall: Coefficient
    public var tierUnknown: Coefficient
    public var inputToOutputRatio: Coefficient
    public var cacheReadToInputRatio: Coefficient
    public var cacheWriteToInputRatio: Coefficient
    public var annualEfficiencyFactor: Coefficient
    public var referenceGenerationMs: Int64
    public var maxTrendYears: Double
}

public struct GridSettings: Codable, Sendable, Hashable {
    public var gramsCO2PerKWh: Double
    public var pue: Double

    enum CodingKeys: String, CodingKey {
        case gramsCO2PerKWh = "gramsCo2PerKwh"
        case pue
    }
}

public struct ScanInfo: Codable, Sendable {
    public var filesFound: Int
    public var filesParsed: Int
    public var responses: Int
    public var issues: [String]
}

public struct Counterfactual: Codable, Sendable, Hashable {
    public var actual: Double
    public var onReferenceModels: Double
    public var withoutCaching: Double
}

public struct YearInReview: Codable, Sendable {
    public struct Share: Codable, Sendable, Hashable {
        public var name: String
        public var grams: Double
        public var fraction: Double
    }

    public struct Day: Codable, Sendable, Hashable {
        public var dateMs: Int64
        public var grams: Double
        public var date: Date { Date(milliseconds: dateMs) }
    }

    public var year: Int
    public var summary: Summary
    public var projectCount: Int
    public var activeDays: Int
    public var longestStreak: Int
    public var busiestDay: Day?
    public var hourly: [Double]
    public var monthly: [Double]
    public var topModel: Share?
    /// Basename of the top project. Never put this on shareable output.
    public var topProject: Share?
    public var counterfactual: Counterfactual
    public var totalGrams: Double
    public var dividendGrams: Double
    public var novelsWritten: Double
    public var tokensRead: Int
    public var peakHour: Int?
    public var nightShare: Double
    public var busiestMonth: Int?
}

public struct Snapshot: Codable, Sendable {
    /// The engine snapshot schema this build understands.
    public static let supportedSchemaVersion = 1

    public var schemaVersion: Int
    public var engineVersion: String
    public var generatedAtMs: Int64
    public var scan: ScanInfo
    public var grid: GridSettings
    public var firstRecordMs: Int64?
    public var periods: [PeriodSnapshot]
    public var equivalents: [Equivalent]
    public var citations: [Citation]
    public var coefficients: EnergyCoefficients
    /// Set from December 1 to January 15: the year the review covers.
    public var seasonalYear: Int?
    public var review: YearInReview
    /// This machine's host name (engine 0.2+).
    public var localMachine: String?
    /// Remote machines whose usage is included (engine 0.2+).
    public var remotes: [RemoteStatus]?

    public func period(_ period: Period) -> PeriodSnapshot? {
        periods.first { $0.period == period }
    }

    public func equivalent(_ id: String) -> Equivalent? {
        equivalents.first { $0.id == id }
    }

    /// Units of equivalent `id` for `grams`, or 0 if the engine doesn't know it.
    public func units(_ id: String, of grams: Double) -> Double {
        equivalent(id)?.units(for: grams) ?? 0
    }

    public func citation(_ id: String) -> Citation? {
        citations.first { $0.id == id }
    }
}

extension Date {
    public init(milliseconds: Int64) {
        self.init(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}
