import Foundation

/// The numbers behind the December "Year in Carbon" slideshow.
public struct YearInReview: Sendable {
    public struct Share: Sendable, Hashable {
        public var name: String
        public var grams: Double
        public var fraction: Double
    }

    public struct Day: Sendable, Hashable {
        public var date: Date
        public var grams: Double
    }

    /// Rough tokens in a novel: ~90k words at ~1.33 tokens per English word.
    public static let tokensPerNovel = 120_000.0

    public let year: Int
    public let summary: Summary
    public let projectCount: Int
    public let activeDays: Int
    public let longestStreak: Int
    public let busiestDay: Day?
    /// Central grams by local hour of day, 0...23.
    public let hourly: [Double]
    /// Central grams by month, January first; always 12 entries.
    public let monthly: [Double]
    public let topModel: Share?
    public let topProject: Share?

    public var totalGrams: Double { summary.footprint.co2Grams.central }
    public var dividendGrams: Double { summary.footprint.efficiencyDividendGrams }
    public var novelsWritten: Double { Double(summary.tokens.output) / Self.tokensPerNovel }
    public var tokensRead: Int { summary.tokens.input + summary.tokens.cacheWrite + summary.tokens.cacheRead }

    public var peakHour: Int? {
        guard totalGrams > 0 else { return nil }
        return hourly.indices.max { hourly[$0] < hourly[$1] }
    }

    /// Share of emissions between 10 pm and 6 am.
    public var nightShare: Double {
        guard totalGrams > 0 else { return 0 }
        let night = (22..<24).map { hourly[$0] }.reduce(0, +) + (0..<6).map { hourly[$0] }.reduce(0, +)
        return night / totalGrams
    }

    public var busiestMonth: Int? {
        guard totalGrams > 0 else { return nil }
        return monthly.indices.max { monthly[$0] < monthly[$1] }.map { $0 + 1 }
    }

    public init(report: UsageReport, year: Int, calendar: Calendar = .current) {
        self.year = year
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
        let interval = DateInterval(start: start, end: end)

        var summary = Summary()
        var hourly = Array(repeating: 0.0, count: 24)
        var monthly = Array(repeating: 0.0, count: 12)
        var byDay: [Date: Double] = [:]
        var byModel: [String: Double] = [:]
        var byProject: [String: Double] = [:]

        for entry in report.entries(in: interval) {
            let grams = entry.footprint.co2Grams.central
            let time = entry.record.timestamp
            summary.tokens += entry.record.tokens
            summary.footprint += entry.footprint
            summary.responses += 1
            hourly[calendar.component(.hour, from: time)] += grams
            monthly[calendar.component(.month, from: time) - 1] += grams
            byDay[calendar.startOfDay(for: time), default: 0] += grams
            byModel[entry.profile.id, default: 0] += grams
            if let project = entry.record.project {
                byProject[(project as NSString).lastPathComponent, default: 0] += grams
            }
        }

        self.summary = summary
        self.hourly = hourly
        self.monthly = monthly
        self.projectCount = byProject.count
        self.activeDays = byDay.count
        self.busiestDay = byDay.max { $0.value < $1.value }.map { Day(date: $0.key, grams: $0.value) }

        let total = summary.footprint.co2Grams.central
        func top(_ buckets: [String: Double]) -> Share? {
            guard total > 0, let best = buckets.max(by: { $0.value < $1.value }) else { return nil }
            return Share(name: best.key, grams: best.value, fraction: best.value / total)
        }
        self.topModel = top(byModel)
        self.topProject = top(byProject)

        var longest = 0
        var run = 0
        var previous: Date?
        for day in byDay.keys.sorted() {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }
        self.longestStreak = longest
    }

    /// Show the review from December 1 through January 15 (reviewing the year just ended).
    public static func seasonalYear(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = c.year, let month = c.month, let day = c.day else { return nil }
        if month == 12 { return year }
        if month == 1 && day <= 15 { return year - 1 }
        return nil
    }
}
