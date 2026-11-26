import Foundation
import Testing
@testable import SuperwarmCore

@Suite struct CodexParserTests {
    func tokenCount(ordinal: Int, total: (Int, Int, Int), last: (Int, Int, Int)) -> String {
        """
        {"timestamp":"2026-10-26T01:55:24.585Z","ordinal":\(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(total.0),"cached_input_tokens":\(total.1),"output_tokens":\(total.2)},"last_token_usage":{"input_tokens":\(last.0),"cached_input_tokens":\(last.1),"output_tokens":\(last.2)}}}}
        """
    }

    let header = """
    {"timestamp":"2026-10-25T18:22:22.263Z","type":"session_meta","payload":{"id":"sess-1","cwd":"/work/app"}}
    {"timestamp":"2026-10-25T18:22:22.512Z","type":"turn_context","payload":{"model":"gpt-5.1-codex","cwd":"/work/app"}}
    """

    @Test func usesDeltasAndSkipsDuplicateEvents() throws {
        let lines = [
            header,
            tokenCount(ordinal: 1, total: (1000, 800, 50), last: (1000, 800, 50)),
            tokenCount(ordinal: 2, total: (1000, 800, 50), last: (1000, 800, 50)),  // duplicate
            tokenCount(ordinal: 3, total: (3000, 2500, 80), last: (2000, 1700, 30)),
        ].joined(separator: "\n")
        let records = try CodexParser().parse(data: Data(lines.utf8))
        #expect(records.count == 2)
        #expect(records[0].tokens == TokenCounts(input: 200, cacheWrite: 0, cacheRead: 800, output: 50))
        #expect(records[1].tokens == TokenCounts(input: 300, cacheWrite: 0, cacheRead: 1700, output: 30))
        #expect(records.allSatisfy { $0.model == "gpt-5.1-codex" && $0.project == "/work/app" })
        #expect(records[1].id == "cx:sess-1:3")
    }

    @Test func resumedSessionCountsOnlyLastTurnFirst() throws {
        // A resumed session starts with a large inherited total.
        let lines = [header, tokenCount(ordinal: 1, total: (900_000, 800_000, 9_000), last: (5000, 4000, 100))]
            .joined(separator: "\n")
        let records = try CodexParser().parse(data: Data(lines.utf8))
        #expect(records.count == 1)
        #expect(records[0].tokens.output == 100)
    }

    @Test func totalResetFallsBackToLast() throws {
        let lines = [
            header,
            tokenCount(ordinal: 1, total: (5000, 0, 500), last: (5000, 0, 500)),
            tokenCount(ordinal: 2, total: (1000, 0, 40), last: (1000, 0, 40)),
        ].joined(separator: "\n")
        let records = try CodexParser().parse(data: Data(lines.utf8))
        #expect(records.map(\.tokens.output) == [500, 40])
    }
}
