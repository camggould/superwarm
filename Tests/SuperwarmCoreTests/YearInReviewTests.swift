import Foundation
import Testing
@testable import SuperwarmCore

@Suite struct YearInReviewTests {
    let calendar = Calendar(identifier: .gregorian)

    func record(_ id: String, _ y: Int, _ m: Int, _ d: Int, hour: Int, model: String = "claude-opus-4-5",
                project: String = "/code/app", output: Int = 1_000) -> UsageRecord {
        UsageRecord(id: id, timestamp: calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!,
                    provider: .claudeCode, model: model, project: project, tokens: TokenCounts(output: output))
    }

    @Test func summarisesTheYear() throws {
        let records = [
            record("a", 2026, 3, 1, hour: 23),
            record("b", 2026, 3, 2, hour: 23, output: 3_000),
            record("c", 2026, 3, 3, hour: 10, model: "claude-haiku-4-5", project: "/code/site"),
            record("d", 2026, 3, 10, hour: 10),
            record("e", 2025, 12, 31, hour: 10),  // previous year, excluded
        ]
        let review = YearInReview(report: UsageReport(records: records, model: EmissionsModel()), year: 2026, calendar: calendar)
        #expect(review.summary.responses == 4)
        #expect(review.activeDays == 4)
        #expect(review.longestStreak == 3)
        #expect(review.projectCount == 2)
        #expect(review.busiestMonth == 3)
        #expect(review.peakHour == 23)
        #expect(review.nightShare > 0.5)
        let busiest = try #require(review.busiestDay)
        #expect(calendar.component(.day, from: busiest.date) == 2)
        #expect(review.topModel?.name == "claude-opus-4-5")
        #expect(review.topProject?.name == "app")
        #expect(abs(review.monthly.reduce(0, +) - review.totalGrams) < 1e-9)
    }

    @Test func emptyYear() {
        let review = YearInReview(report: UsageReport(records: [], model: EmissionsModel()), year: 2026, calendar: calendar)
        #expect(review.totalGrams == 0)
        #expect(review.peakHour == nil)
        #expect(review.topModel == nil)
        #expect(review.longestStreak == 0)
    }

    @Test func seasonRunsDecemberToMidJanuary() {
        func at(_ y: Int, _ m: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d))! }
        #expect(YearInReview.seasonalYear(now: at(2026, 11, 30), calendar: calendar) == nil)
        #expect(YearInReview.seasonalYear(now: at(2026, 12, 1), calendar: calendar) == 2026)
        #expect(YearInReview.seasonalYear(now: at(2027, 1, 15), calendar: calendar) == 2026)
        #expect(YearInReview.seasonalYear(now: at(2027, 1, 16), calendar: calendar) == nil)
    }
}
