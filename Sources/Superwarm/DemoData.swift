import Foundation
import SuperwarmCore

/// A deterministic, synthetic year of coding-agent usage for screenshots and
/// demos, so documentation never shows anyone's real logs.
enum DemoData {
    /// SplitMix64: tiny, seedable, and identical on every machine.
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func records(now: Date = Date(), calendar: Calendar = .current) -> [UsageRecord] {
        var rng = Generator(state: 2026)
        let projects = ["/Users/demo/code/acme-web", "/Users/demo/code/data-pipeline",
                        "/Users/demo/code/mobile-app", "/Users/demo/code/dotfiles"]
        let year = calendar.component(.year, from: now)
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let today = calendar.startOfDay(for: now)
        var records: [UsageRecord] = []
        var day = start
        var serial = 0

        while day <= today {
            let weekday = calendar.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7
            let month = calendar.component(.month, from: day)
            // Usage ramps up through the year; weekends are quieter.
            let intensity = (0.35 + Double(month) / 12) * (weekend ? 0.3 : 1)
            let sessions = Int((Double.random(in: 0...4, using: &rng) * intensity).rounded())

            for _ in 0..<sessions {
                let evening = Double.random(in: 0...1, using: &rng) < 0.2
                let hour = evening ? Int.random(in: 20...23, using: &rng) : Int.random(in: 9...17, using: &rng)
                var time = calendar.date(byAdding: .hour, value: hour, to: day)!
                guard time <= now else { continue }
                let project = projects[Int.random(in: 0..<projects.count, using: &rng)]
                let (provider, model) = pickModel(month: month, using: &rng)
                let turns = Int.random(in: 15...70, using: &rng)
                var context = Int.random(in: 20_000...40_000, using: &rng)

                for _ in 0..<turns {
                    serial += 1
                    let output = Int.random(in: 150...2_400, using: &rng)
                    let written = Int.random(in: 500...6_000, using: &rng)
                    records.append(UsageRecord(
                        id: "demo:\(serial)", timestamp: time, provider: provider, model: model, project: project,
                        tokens: TokenCounts(input: Int.random(in: 1...40, using: &rng), cacheWrite: written,
                                            cacheRead: context, output: output)
                    ))
                    context = min(context + written + output, 180_000)
                    time = time.addingTimeInterval(Double.random(in: 20...140, using: &rng))
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return records
    }

    private static func pickModel(month: Int, using rng: inout Generator) -> (Provider, String) {
        let roll = Double.random(in: 0...1, using: &rng)
        if roll < 0.22 { return (.codex, month < 6 ? "gpt-5-codex" : "gpt-5.1-codex") }
        if roll < 0.32 { return (.claudeCode, "claude-haiku-4-5-20251001") }
        if roll < 0.55 { return (.claudeCode, "claude-sonnet-4-5-20250929") }
        return (.claudeCode, "claude-opus-4-5-20251101")
    }
}
