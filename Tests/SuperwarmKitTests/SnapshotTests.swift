import Foundation
import Testing
@testable import SuperwarmKit

/// The contract between the Rust engine and the app. The fixture is real
/// engine output: `engine/target/release/superwarm --demo snapshot`.
/// Regenerate it whenever the snapshot schema changes.
@Suite struct SnapshotTests {
    func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "demo-snapshot", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func decodesEngineSnapshot() throws {
        let snapshot = try Engine.decode(fixture())
        #expect(snapshot.schemaVersion == Snapshot.supportedSchemaVersion)
        #expect(snapshot.periods.map(\.period) == Period.allCases)
        let month = try #require(snapshot.period(.month))
        #expect(month.summary.footprint.co2Grams.low < month.summary.footprint.co2Grams.central)
        #expect(month.headline.count == 3)
        #expect(month.headline.allSatisfy { snapshot.equivalent($0) != nil })
        #expect(!month.timeline.isEmpty)
        #expect(snapshot.equivalents.allSatisfy { snapshot.citation($0.citationId) != nil })
        #expect(snapshot.review.monthly.count == 12)
        #expect(snapshot.review.counterfactual.withoutCaching > snapshot.review.counterfactual.onReferenceModels)
        #expect(snapshot.coefficients.baseWhPer1kOutput.central == 0.9)
    }

    @Test func rejectsOtherSchemaVersions() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        json["schemaVersion"] = Snapshot.supportedSchemaVersion + 1
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: EngineError.incompatible(schemaVersion: Snapshot.supportedSchemaVersion + 1)) {
            try Engine.decode(data)
        }
        #expect(throws: EngineError.self) { try Engine.decode(Data("nope".utf8)) }
    }

    @Test func passesSettingsToTheEngine() {
        let args = EngineOptions(gramsCO2PerKWh: 50, pue: 1.1, commuteMilesOneWay: 5, demo: true).arguments
        #expect(args == ["snapshot", "--grid", "50.0", "--pue", "1.1", "--commute", "5.0", "--demo"])
    }

    /// Runs the real engine when it has been built (`cargo build --release` in engine/).
    @Test func liveEngineProducesADecodableSnapshot() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = repo.appendingPathComponent("engine/target/release/superwarm")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
        let snapshot = try Engine(executable: binary).snapshot(EngineOptions(demo: true))
        #expect(snapshot.scan.responses > 0)
        #expect(snapshot.period(.allTime)?.summary.responses == snapshot.scan.responses)
    }

    @Test func formatting() {
        #expect(Format.grams(0.5) == "0.5 g")
        #expect(Format.grams(0) == "0 g")
        #expect(Format.grams(1_234) == "1.23 kg")
        #expect(Format.grams(45_590) == "45.6 kg")
        #expect(Format.grams(266_800) == "267 kg")
        #expect(Format.grams(10_000) == "10 kg")
        #expect(Format.energy(wh: 2_500) == "2.5 kWh")
        #expect(Format.count(12_345) == "12.3k")
    }
}
