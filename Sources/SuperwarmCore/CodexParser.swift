import Foundation

/// Parses Codex rollout files (`~/.codex/sessions/**/rollout-*.jsonl[.zst]`).
///
/// Codex emits `token_count` events carrying a running `total_token_usage`.
/// Events are sometimes repeated, so each record is the *increase* in the
/// running total. The first event in a file, and any event where the total
/// went backwards (a reset), falls back to `last_token_usage`, so a resumed
/// session does not re-count the history it inherited.
public struct CodexParser: Sendable {
    public static let needles = ["\"token_count\"", "\"turn_context\"", "\"session_meta\""].map { Data($0.utf8) }

    public init() {}

    public func parse(url: URL) throws -> [UsageRecord] {
        var state = State(fallbackSessionID: url.deletingPathExtension().lastPathComponent)
        try LineReader.forEachLine(in: url, containingAny: Self.needles) { line in
            state.consume(line)
        }
        return state.records
    }

    public func parse(data: Data, sessionID: String = "test") throws -> [UsageRecord] {
        var state = State(fallbackSessionID: sessionID)
        try LineReader.forEachLine(in: data, containingAny: Self.needles) { state.consume($0) }
        return state.records
    }

    struct Usage: Equatable {
        var input = 0, cached = 0, cacheWrite = 0, output = 0

        init(_ dict: [String: Any]) {
            input = dict.int("input_tokens")
            cached = dict.int("cached_input_tokens")
            cacheWrite = dict.int("cache_write_input_tokens")
            output = dict.int("output_tokens")
        }

        init(input: Int, cached: Int, cacheWrite: Int, output: Int) {
            self.input = input; self.cached = cached; self.cacheWrite = cacheWrite; self.output = output
        }

        static func - (a: Usage, b: Usage) -> Usage {
            Usage(input: a.input - b.input, cached: a.cached - b.cached,
                  cacheWrite: a.cacheWrite - b.cacheWrite, output: a.output - b.output)
        }

        var isNegative: Bool { input < 0 || cached < 0 || cacheWrite < 0 || output < 0 }
        var isZero: Bool { input == 0 && cached == 0 && cacheWrite == 0 && output == 0 }

        /// OpenAI's `input_tokens` includes cached tokens; split them out.
        var tokens: TokenCounts {
            TokenCounts(
                input: max(0, input - cached - cacheWrite),
                cacheWrite: cacheWrite,
                cacheRead: cached,
                output: output
            )
        }
    }

    struct State {
        var sessionID: String
        var model = "unknown-codex-model"
        var cwd: String?
        var previousTotal: Usage?
        var lineNumber = 0
        var records: [UsageRecord] = []

        init(fallbackSessionID: String) { sessionID = fallbackSessionID }

        mutating func consume(_ line: Data) {
            lineNumber += 1
            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let type = object["type"] as? String,
                let payload = object["payload"] as? [String: Any]
            else { return }

            switch type {
            case "session_meta":
                if let id = payload["id"] as? String ?? payload["session_id"] as? String { sessionID = id }
                cwd = payload["cwd"] as? String ?? cwd
            case "turn_context":
                if let m = payload["model"] as? String { model = m }
                cwd = payload["cwd"] as? String ?? cwd
            case "event_msg":
                guard payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let totalDict = info["total_token_usage"] as? [String: Any],
                      let timestampString = object["timestamp"] as? String,
                      let timestamp = Timestamp.parse(timestampString)
                else { return }
                let total = Usage(totalDict)
                let last = (info["last_token_usage"] as? [String: Any]).map(Usage.init)
                let increment: Usage
                if let previous = previousTotal {
                    let delta = total - previous
                    if delta.isZero { return }  // duplicate event
                    increment = delta.isNegative ? (last ?? total) : delta
                } else {
                    increment = last ?? total
                }
                previousTotal = total
                let tokens = increment.tokens
                guard !tokens.isZero else { return }
                let ordinal = (object["ordinal"] as? Int).map(String.init) ?? "l\(lineNumber)"
                records.append(UsageRecord(
                    id: "cx:\(sessionID):\(ordinal)",
                    timestamp: timestamp,
                    provider: .codex,
                    model: model,
                    project: cwd,
                    tokens: tokens
                ))
            default:
                return
            }
        }
    }
}
