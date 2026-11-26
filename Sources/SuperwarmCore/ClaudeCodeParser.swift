import Foundation

/// Parses Claude Code session transcripts (`~/.claude/projects/**/*.jsonl`).
///
/// Every assistant line carries the API `usage` block for its response.
/// Claude Code writes one line per content block, so a single response can
/// appear several times; records are keyed by message id + request id so the
/// store can merge them.
public struct ClaudeCodeParser: Sendable {
    public static let needles = [Data("\"usage\"".utf8)]

    public init() {}

    public func parse(url: URL) throws -> [UsageRecord] {
        var records: [String: UsageRecord] = [:]
        var order: [String] = []
        try LineReader.forEachLine(in: url, containingAny: Self.needles) { line in
            guard let record = parse(line: line) else { return }
            if let existing = records[record.id] {
                records[record.id]?.tokens = existing.tokens.fieldwiseMax(record.tokens)
            } else {
                records[record.id] = record
                order.append(record.id)
            }
        }
        return order.compactMap { records[$0] }
    }

    public func parse(line: Data) -> UsageRecord? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            object["type"] as? String == "assistant",
            let message = object["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any],
            let model = message["model"] as? String,
            !model.hasPrefix("<"),  // "<synthetic>" placeholder messages are not API calls
            let timestampString = object["timestamp"] as? String,
            let timestamp = Timestamp.parse(timestampString)
        else { return nil }

        let tokens = TokenCounts(
            input: usage.int("input_tokens"),
            cacheWrite: usage.int("cache_creation_input_tokens"),
            cacheRead: usage.int("cache_read_input_tokens"),
            output: usage.int("output_tokens")
        )
        guard !tokens.isZero else { return nil }

        let messageID = message["id"] as? String ?? object["uuid"] as? String ?? UUID().uuidString
        let requestID = object["requestId"] as? String ?? ""
        return UsageRecord(
            id: "cc:\(messageID):\(requestID)",
            timestamp: timestamp,
            provider: .claudeCode,
            model: model,
            project: object["cwd"] as? String,
            tokens: tokens
        )
    }
}

extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) -> Int {
        switch self[key] {
        case let value as Int: value
        case let value as Double: Int(value)
        case let value as NSNumber: value.intValue
        default: 0
        }
    }
}
