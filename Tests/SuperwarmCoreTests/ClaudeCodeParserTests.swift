import Foundation
import Testing
@testable import SuperwarmCore

@Suite struct ClaudeCodeParserTests {
    func line(id: String = "msg_1", req: String = "req_1", model: String = "claude-opus-4-5-20251101", output: Int = 100) -> String {
        """
        {"type":"assistant","timestamp":"2026-11-01T10:00:00.123Z","requestId":"\(req)","cwd":"/tmp/proj","message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":5,"cache_creation_input_tokens":1000,"cache_read_input_tokens":20000,"output_tokens":\(output)}}}
        """
    }

    @Test func parsesUsageLine() throws {
        let record = try #require(ClaudeCodeParser().parse(line: Data(line().utf8)))
        #expect(record.id == "cc:msg_1:req_1")
        #expect(record.provider == .claudeCode)
        #expect(record.project == "/tmp/proj")
        #expect(record.tokens == TokenCounts(input: 5, cacheWrite: 1000, cacheRead: 20000, output: 100))
    }

    @Test func mergesStreamedDuplicatesWithFieldwiseMax() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("s.jsonl")
        let text = [line(output: 3), line(output: 250), line(id: "msg_2", req: "req_2", output: 7)].joined(separator: "\n")
        try text.write(to: file, atomically: true, encoding: .utf8)

        let records = try ClaudeCodeParser().parse(url: file)
        #expect(records.count == 2)
        #expect(records[0].tokens.output == 250)
        #expect(records[1].tokens.output == 7)
    }

    @Test func skipsSyntheticAndNonAssistantLines() {
        let parser = ClaudeCodeParser()
        #expect(parser.parse(line: Data(line(model: "<synthetic>").utf8)) == nil)
        let user = #"{"type":"user","timestamp":"2026-11-01T10:00:00Z","message":{"usage":{}}}"#
        #expect(parser.parse(line: Data(user.utf8)) == nil)
    }
}
