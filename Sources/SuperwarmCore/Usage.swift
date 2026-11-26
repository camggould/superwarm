import Foundation

/// The coding tool a usage record came from.
public enum Provider: String, Codable, Sendable, CaseIterable, Hashable {
    case claudeCode
    case codex

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// Token counts for one model call, split by how much compute each kind costs.
///
/// `input` counts only *uncached* prompt tokens. Prompt-cache reads and writes
/// are tracked separately because they cost very different amounts of compute.
public struct TokenCounts: Codable, Sendable, Hashable {
    public var input: Int
    public var cacheWrite: Int
    public var cacheRead: Int
    public var output: Int

    public init(input: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, output: Int = 0) {
        self.input = input
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.output = output
    }

    public static let zero = TokenCounts()

    public var total: Int { input + cacheWrite + cacheRead + output }
    public var isZero: Bool { total == 0 }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            output: lhs.output + rhs.output
        )
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) { lhs = lhs + rhs }

    /// Field-wise maximum. Used to merge duplicate log lines for the same API response.
    public func fieldwiseMax(_ other: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: max(input, other.input),
            cacheWrite: max(cacheWrite, other.cacheWrite),
            cacheRead: max(cacheRead, other.cacheRead),
            output: max(output, other.output)
        )
    }
}

/// One billed model response, as recovered from a local log file.
public struct UsageRecord: Codable, Sendable, Hashable {
    /// Globally unique key used to deduplicate the same response logged twice.
    public var id: String
    public var timestamp: Date
    public var provider: Provider
    public var model: String
    public var project: String?
    public var tokens: TokenCounts

    public init(id: String, timestamp: Date, provider: Provider, model: String, project: String?, tokens: TokenCounts) {
        self.id = id
        self.timestamp = timestamp
        self.provider = provider
        self.model = model
        self.project = project
        self.tokens = tokens
    }
}

enum Timestamp {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let lock = NSLock()

    static func parse(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: string) ?? plain.date(from: string)
    }
}

/// Where Superwarm keeps its own files.
public enum AppPaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Superwarm", isDirectory: true)
    }
}
