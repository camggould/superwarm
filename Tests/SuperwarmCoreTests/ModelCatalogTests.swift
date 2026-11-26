import Foundation
import Testing
@testable import SuperwarmCore

@Suite struct ModelCatalogTests {
    @Test(arguments: [
        ("claude-haiku-4-5-20251001", "claude-haiku-4-5"),
        ("anthropic.claude-sonnet-4-5-20250929-v1:0", "claude-sonnet-4-5"),
        ("openai/gpt-4o-2024-08-06", "gpt-4o"),
        ("claude-opus-5-5[1m]", "claude-opus-5-5"),
    ])
    func normalizes(raw: String, expected: String) {
        #expect(ModelCatalog.normalize(raw) == expected)
    }

    @Test(arguments: [
        ("claude-opus-4-5", ModelTier.large), ("claude-sonnet-4-5", .medium), ("claude-haiku-4-5", .small),
        ("gpt-5", .large), ("gpt-4o-mini", .small), ("gpt-4.1-nano", .small), ("o3", .large),
        ("gemini-2.5-flash", .small), ("codex-auto-review", .unknown),
    ])
    func infersTier(id: String, tier: ModelTier) {
        #expect(ModelCatalog.tier(for: id) == tier)
    }

    @Test func prefixNeverSwallowsNewerVersion() {
        #expect(ModelCatalog.matches("claude-opus-4-thinking", prefix: "claude-opus-4"))
        #expect(!ModelCatalog.matches("claude-opus-4-8", prefix: "claude-opus-4"))
        #expect(!ModelCatalog.matches("gpt-5.5", prefix: "gpt-5"))
        #expect(!ModelCatalog.matches("gpt-50", prefix: "gpt-5"))
    }

    @Test func usesCatalogThenFirstSeen() {
        let seen = Date(timeIntervalSince1970: 1_790_000_000)
        let catalog = ModelCatalog(firstSeen: ["claude-opus-4-8": seen])
        let known = catalog.profile(for: "claude-opus-4-5-20251101")
        #expect(known.generationSource == .catalog)
        #expect(Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: known.generation).month == 11)
        let unknown = catalog.profile(for: "claude-opus-4-8")
        #expect(unknown.generationSource == .firstSeen)
        #expect(unknown.generation == seen)
    }

    @Test func overrideWins() {
        let catalog = ModelCatalog(overrides: [ModelOverride(prefix: "gpt-6", tier: .medium, released: "2026-03")])
        let p = catalog.profile(for: "gpt-6-luna")
        #expect(p.tier == .medium)
        #expect(p.generationSource == .override)
    }
}
