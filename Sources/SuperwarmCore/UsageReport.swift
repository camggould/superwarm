import Foundation

public enum Period: String, CaseIterable, Sendable, Identifiable {
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

    /// `nil` means unbounded.
    public func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        let startOfToday = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        let start: Date
        switch self {
        case .today: start = startOfToday
        case .week: start = calendar.date(byAdding: .day, value: -6, to: startOfToday)!
        case .month: start = calendar.date(byAdding: .day, value: -29, to: startOfToday)!
        case .year: start = calendar.date(byAdding: .day, value: -364, to: startOfToday)!
        case .allTime: return nil
        }
        return DateInterval(start: start, end: end)
    }
}

public struct Summary: Sendable {
    public var tokens: TokenCounts = .zero
    public var footprint: Footprint = .zero
    public var responses = 0

    public init() {}
}

public struct TimelinePoint: Sendable, Identifiable, Hashable {
    /// Start of the bucket (hour, day, week or month).
    public var start: Date
    public var provider: Provider
    public var co2Grams: Double
    public var energyWh: Double
    public var id: String { "\(start.timeIntervalSince1970)-\(provider.rawValue)" }
}

public struct ModelBreakdown: Sendable, Identifiable {
    public var profile: ModelProfile
    public var provider: Provider
    public var summary: Summary
    public var id: String { "\(provider.rawValue):\(profile.id)" }

    /// Central grams of CO2e per million tokens of all kinds, a rough efficiency score.
    public var gramsPerMillionTokens: Double {
        let total = summary.tokens.total
        return total > 0 ? summary.footprint.co2Grams.central / Double(total) * 1_000_000 : 0
    }

    /// Central grams of CO2e per thousand output tokens. Easier to compare across
    /// models because it ignores how cache-heavy each model's sessions were.
    public var gramsPerThousandOutput: Double {
        let output = summary.tokens.output
        return output > 0 ? summary.footprint.co2Grams.central / Double(output) * 1_000 : 0
    }
}

public struct ProjectBreakdown: Sendable, Identifiable {
    public var path: String
    public var summary: Summary
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

/// All usage with each record's footprint already computed.
public struct UsageReport: Sendable {
    public struct Entry: Sendable {
        public var record: UsageRecord
        public var profile: ModelProfile
        public var footprint: Footprint
    }

    public let entries: [Entry]
    public let model: EmissionsModel
    public let catalog: ModelCatalog

    public init(records: [UsageRecord], model: EmissionsModel, overrides: [ModelOverride] = []) {
        let catalog = ModelCatalog(records: records, overrides: overrides)
        var profiles: [String: ModelProfile] = [:]
        self.entries = records.map { record in
            let profile = profiles[record.model] ?? catalog.profile(for: record.model, usedAt: record.timestamp)
            profiles[record.model] = profile
            return Entry(record: record, profile: profile, footprint: model.footprint(tokens: record.tokens, profile: profile))
        }
        self.model = model
        self.catalog = catalog
    }

    func entries(in interval: DateInterval?) -> some Sequence<Entry> {
        entries.lazy.filter { entry in
            guard let interval else { return true }
            return entry.record.timestamp >= interval.start && entry.record.timestamp < interval.end
        }
    }

    public func summary(in interval: DateInterval?) -> Summary {
        var summary = Summary()
        for entry in entries(in: interval) {
            summary.tokens += entry.record.tokens
            summary.footprint += entry.footprint
            summary.responses += 1
        }
        return summary
    }

    /// Natural chart resolution for each period.
    public static func bucket(for period: Period) -> Calendar.Component {
        switch period {
        case .today: .hour
        case .week, .month: .day
        case .year: .weekOfYear
        case .allTime: .month
        }
    }

    /// CO2 and energy per time bucket and provider.
    public func timeline(in interval: DateInterval?, by unit: Calendar.Component, calendar: Calendar = .current) -> [TimelinePoint] {
        var buckets: [String: TimelinePoint] = [:]
        for entry in entries(in: interval) {
            let start = calendar.dateInterval(of: unit, for: entry.record.timestamp)?.start ?? entry.record.timestamp
            let key = "\(start.timeIntervalSince1970)-\(entry.record.provider.rawValue)"
            var point = buckets[key] ?? TimelinePoint(start: start, provider: entry.record.provider, co2Grams: 0, energyWh: 0)
            point.co2Grams += entry.footprint.co2Grams.central
            point.energyWh += entry.footprint.energyWh.central
            buckets[key] = point
        }
        return buckets.values.sorted { ($0.start, $0.provider.rawValue) < ($1.start, $1.provider.rawValue) }
    }

    public func byModel(in interval: DateInterval?) -> [ModelBreakdown] {
        var buckets: [String: ModelBreakdown] = [:]
        for entry in entries(in: interval) {
            let key = "\(entry.record.provider.rawValue):\(entry.profile.id)"
            var item = buckets[key] ?? ModelBreakdown(profile: entry.profile, provider: entry.record.provider, summary: Summary())
            item.summary.tokens += entry.record.tokens
            item.summary.footprint += entry.footprint
            item.summary.responses += 1
            buckets[key] = item
        }
        return buckets.values.sorted { $0.summary.footprint.co2Grams.central > $1.summary.footprint.co2Grams.central }
    }

    public func byProject(in interval: DateInterval?) -> [ProjectBreakdown] {
        var buckets: [String: ProjectBreakdown] = [:]
        for entry in entries(in: interval) {
            let path = entry.record.project ?? "Unknown"
            var item = buckets[path] ?? ProjectBreakdown(path: path, summary: Summary())
            item.summary.tokens += entry.record.tokens
            item.summary.footprint += entry.footprint
            item.summary.responses += 1
            buckets[path] = item
        }
        return buckets.values.sorted { $0.summary.footprint.co2Grams.central > $1.summary.footprint.co2Grams.central }
    }
}
