import Foundation

/// A rough size class for a model. Vendors don't publish parameter counts for
/// closed models, so the tier is inferred from the product line (Opus/Sonnet/Haiku,
/// flagship/mini/nano) and later scaled by a per-tier energy multiplier.
public enum ModelTier: String, Codable, Sendable, CaseIterable {
    case large, medium, small, unknown

    public var displayName: String {
        switch self {
        case .large: "Large"
        case .medium: "Medium"
        case .small: "Small"
        case .unknown: "Unknown"
        }
    }
}

public enum GenerationSource: String, Codable, Sendable {
    /// Public release month from the built-in catalog.
    case catalog
    /// Not in the catalog: the earliest time this model shows up in your logs.
    /// This is a *late* bound on the release date when your log history is
    /// short, so it can over-credit the efficiency trend; add an override.
    case firstSeen
    /// From the user's `models.json` override file.
    case override
}

/// A user-supplied correction for a model the built-in catalog doesn't know.
///
/// `~/Library/Application Support/Superwarm/models.json`:
/// `[{"prefix": "claude-opus-5", "tier": "large", "released": "2026-05"}]`
public struct ModelOverride: Codable, Sendable, Hashable {
    public var prefix: String
    public var tier: ModelTier?
    /// "YYYY-MM"
    public var released: String?

    public init(prefix: String, tier: ModelTier? = nil, released: String? = nil) {
        self.prefix = prefix
        self.tier = tier
        self.released = released
    }

    var releaseDate: Date? {
        guard let released else { return nil }
        let parts = released.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .gmt, year: parts[0], month: parts[1], day: 15))
    }

    public static var defaultURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("models.json")
    }

    public static func load(from url: URL = defaultURL) -> [ModelOverride] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ModelOverride].self, from: data)) ?? []
    }
}

public struct ModelProfile: Sendable, Hashable {
    public var id: String
    public var displayName: String
    public var tier: ModelTier
    /// When the model (and its serving stack) became available. Newer models get
    /// the efficiency-trend discount.
    public var generation: Date
    public var generationSource: GenerationSource
}

public struct ModelCatalog: Sendable {
    struct Entry: Sendable {
        let prefix: String
        let year: Int
        let month: Int
    }

    /// Public release months of models we know about. Matched by prefix on the
    /// normalized id, longest prefix first.
    static let entries: [Entry] = [
        // Anthropic
        Entry(prefix: "claude-3-opus", year: 2024, month: 3),
        Entry(prefix: "claude-3-sonnet", year: 2024, month: 3),
        Entry(prefix: "claude-3-haiku", year: 2024, month: 3),
        Entry(prefix: "claude-3-5-sonnet", year: 2024, month: 6),
        Entry(prefix: "claude-3-5-haiku", year: 2024, month: 11),
        Entry(prefix: "claude-3-7-sonnet", year: 2025, month: 2),
        Entry(prefix: "claude-sonnet-4", year: 2025, month: 5),
        Entry(prefix: "claude-opus-4", year: 2025, month: 5),
        Entry(prefix: "claude-opus-4-1", year: 2025, month: 8),
        Entry(prefix: "claude-sonnet-4-5", year: 2025, month: 9),
        Entry(prefix: "claude-haiku-4-5", year: 2025, month: 10),
        Entry(prefix: "claude-opus-4-5", year: 2025, month: 11),
        // OpenAI
        Entry(prefix: "gpt-4o", year: 2024, month: 5),
        Entry(prefix: "gpt-4o-mini", year: 2024, month: 7),
        Entry(prefix: "o1", year: 2024, month: 12),
        Entry(prefix: "o3-mini", year: 2025, month: 1),
        Entry(prefix: "o3", year: 2025, month: 4),
        Entry(prefix: "o4-mini", year: 2025, month: 4),
        Entry(prefix: "gpt-4.1", year: 2025, month: 4),
        Entry(prefix: "codex-mini", year: 2025, month: 5),
        Entry(prefix: "gpt-5", year: 2025, month: 8),
        Entry(prefix: "gpt-5-codex", year: 2025, month: 9),
        Entry(prefix: "gpt-5.1", year: 2025, month: 11),
    ].sorted { $0.prefix.count > $1.prefix.count }

    /// Earliest timestamp each normalized model id appears in the user's logs.
    public var firstSeen: [String: Date]
    public var overrides: [ModelOverride]

    public init(firstSeen: [String: Date] = [:], overrides: [ModelOverride] = []) {
        self.firstSeen = firstSeen
        self.overrides = overrides.sorted { $0.prefix.count > $1.prefix.count }
    }

    public init(records: [UsageRecord], overrides: [ModelOverride] = []) {
        var seen: [String: Date] = [:]
        for record in records {
            let id = Self.normalize(record.model)
            if let existing = seen[id], existing <= record.timestamp { continue }
            seen[id] = record.timestamp
        }
        self.init(firstSeen: seen, overrides: overrides)
    }

    /// Lowercases and strips dated snapshot suffixes and Bedrock/Vertex style prefixes:
    /// `anthropic.claude-haiku-4-5-20251001-v1:0` -> `claude-haiku-4-5`.
    public static func normalize(_ model: String) -> String {
        var id = model.lowercased()
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        for vendor in ["anthropic.", "openai.", "us.anthropic.", "eu.anthropic."] where id.hasPrefix(vendor) {
            id = String(id.dropFirst(vendor.count))
        }
        if let range = id.range(of: #"-v\d+(:\d+)?$"#, options: .regularExpression) { id.removeSubrange(range) }
        if let range = id.range(of: #"[-@]\d{8}$"#, options: .regularExpression) { id.removeSubrange(range) }
        if let range = id.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) { id.removeSubrange(range) }
        if let range = id.range(of: #"\[.*\]$"#, options: .regularExpression) { id.removeSubrange(range) }
        return id
    }

    public static func tier(for normalizedID: String) -> ModelTier {
        let id = normalizedID
        let smallMarkers = ["haiku", "mini", "nano", "flash", "lite", "small", "8b", "7b", "3b"]
        if smallMarkers.contains(where: id.contains) { return .small }
        if id.contains("sonnet") || id.contains("medium") { return .medium }
        if id.contains("opus") || id.contains("pro") || id.contains("large") { return .large }
        // OpenAI flagship lines without a size suffix: gpt-4o, gpt-5, o3, ...
        if id.hasPrefix("gpt-") || id.range(of: #"^o\d"#, options: .regularExpression) != nil { return .large }
        return .unknown
    }

    public func profile(for model: String, usedAt fallbackDate: Date = Date()) -> ModelProfile {
        let id = Self.normalize(model)
        let override = overrides.first { Self.matches(id, prefix: $0.prefix.lowercased()) }
        let tier = override?.tier ?? Self.tier(for: id)
        let calendar = Calendar(identifier: .gregorian)
        if let released = override?.releaseDate {
            return ModelProfile(id: id, displayName: id, tier: tier, generation: released, generationSource: .override)
        }
        if let entry = Self.entries.first(where: { Self.matches(id, prefix: $0.prefix) }),
           let date = calendar.date(from: DateComponents(timeZone: .gmt, year: entry.year, month: entry.month, day: 15)) {
            return ModelProfile(id: id, displayName: id, tier: tier, generation: date, generationSource: .catalog)
        }
        return ModelProfile(
            id: id,
            displayName: id,
            tier: tier,
            generation: firstSeen[id] ?? fallbackDate,
            generationSource: .firstSeen
        )
    }

    /// A prefix matches only on a token boundary and never swallows a newer
    /// version number: `claude-opus-4` matches `claude-opus-4-thinking` but not
    /// `claude-opus-4-8`, and `gpt-5` does not match `gpt-5.5` or `gpt-50`.
    static func matches(_ id: String, prefix: String) -> Bool {
        guard id.hasPrefix(prefix) else { return false }
        let rest = id.dropFirst(prefix.count)
        guard let next = rest.first else { return true }
        guard next == "-" else { return false }
        return !(rest.dropFirst().first?.isNumber ?? false)
    }
}
