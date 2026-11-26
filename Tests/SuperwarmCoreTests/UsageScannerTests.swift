import Foundation
import Testing
@testable import SuperwarmCore

@Suite struct DeduplicationTests {
    @Test func sameResponseInTwoFilesCountsOnce() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let a = UsageRecord(id: "cc:m:r", timestamp: t, provider: .claudeCode, model: "x", project: nil, tokens: TokenCounts(output: 10))
        var b = a
        b.tokens.output = 12
        let unique = UsageScanner.deduplicate([a, b])
        #expect(unique.count == 1)
        #expect(unique[0].tokens.output == 12)
    }
}

@Suite struct UsageReportTests {
    @Test func aggregatesByPeriodModelAndDay() {
        let now = Date()
        let old = now.addingTimeInterval(-40 * 86_400)
        let records = [
            UsageRecord(id: "a", timestamp: now, provider: .claudeCode, model: "claude-opus-4-5", project: "/p/one", tokens: TokenCounts(output: 1000)),
            UsageRecord(id: "b", timestamp: now, provider: .codex, model: "gpt-5", project: "/p/two", tokens: TokenCounts(output: 500)),
            UsageRecord(id: "c", timestamp: old, provider: .claudeCode, model: "claude-opus-4-5", project: "/p/one", tokens: TokenCounts(output: 1000)),
        ]
        let report = UsageReport(records: records, model: EmissionsModel())
        #expect(report.summary(in: Period.today.interval(now: now)).responses == 2)
        #expect(report.summary(in: Period.month.interval(now: now)).responses == 2)
        #expect(report.summary(in: nil).responses == 3)
        #expect(report.byModel(in: nil).count == 2)
        #expect(report.byModel(in: nil).first?.profile.id == "claude-opus-4-5")
        #expect(report.byProject(in: nil).first?.name == "one")
        #expect(Set(report.timeline(in: Period.today.interval(now: now), by: .day).map(\.provider)) == [.claudeCode, .codex])
    }

    @Test func timelineBucketsByHour() {
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9, minute: 10))!
        let records = [0, 20, 70].map { minutes in
            UsageRecord(id: "r\(minutes)", timestamp: base.addingTimeInterval(Double(minutes) * 60), provider: .claudeCode,
                        model: "claude-opus-4-5", project: nil, tokens: TokenCounts(output: 1000))
        }
        let points = UsageReport(records: records, model: EmissionsModel()).timeline(in: nil, by: .hour, calendar: calendar)
        #expect(points.count == 2)
        #expect(abs(points[0].co2Grams - 2 * points[1].co2Grams) < 1e-9)
        #expect(UsageReport.bucket(for: .today) == .hour)
    }

    @Test func cacheSkipsUnchangedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let line = #"{"type":"assistant","timestamp":"2026-11-01T10:00:00Z","requestId":"r","message":{"id":"m","model":"claude-opus-4-5","usage":{"output_tokens":10}}}"#
        try line.write(to: root.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let scanner = UsageScanner(sources: [LogSource(provider: .claudeCode, roots: [root])])
        var cache = ScanCache()
        #expect(scanner.scan(cache: &cache).filesParsed == 1)
        let second = scanner.scan(cache: &cache)
        #expect(second.filesParsed == 0)
        #expect(second.records.count == 1)
    }
}

@Suite struct ComparisonTests {
    let calendar = Calendar(identifier: .gregorian)

    @Test func previousTodayStopsAtSameTimeYesterday() throws {
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 15))!
        let previous = try #require(Period.today.previousInterval(now: now, calendar: calendar))
        #expect(previous.start == calendar.date(from: DateComponents(year: 2026, month: 11, day: 24)))
        #expect(previous.end == calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 15)))
        #expect(Period.allTime.previousInterval(now: now) == nil)
    }

    @Test func previousWeekIsSevenDaysEarlier() throws {
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 15))!
        let current = try #require(Period.week.interval(now: now, calendar: calendar))
        let previous = try #require(Period.week.previousInterval(now: now, calendar: calendar))
        #expect(calendar.dateComponents([.day], from: previous.start, to: current.start).day == 7)
    }

    @Test func smallerTierWhatIfIsCheaper() {
        let record = UsageRecord(id: "a", timestamp: Date(), provider: .claudeCode, model: "claude-opus-4-5",
                                 project: nil, tokens: TokenCounts(input: 100, cacheRead: 10_000, output: 1_000))
        let report = UsageReport(records: [record], model: EmissionsModel())
        let result = report.whatIf(tier: .large, as: .medium, in: nil)
        #expect(result.actual > 0)
        #expect(abs(result.alternative / result.actual - 0.45) < 1e-9)
        #expect(report.whatIf(tier: .small, as: .medium, in: nil).actual == 0)
    }
}
