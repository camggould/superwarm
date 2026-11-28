import Foundation
import Testing
@testable import SuperwarmKit

/// The app and `superwarm settings` (engine/src/settings.rs) share one file.
struct SharedSettingsTests {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("superwarm-settings-\(UUID().uuidString)/settings.json")

    @Test func missingFileIsMissing() {
        #expect(SharedSettings.read(from: url) == .missing)
    }

    @Test func readsWhatTheEngineWrites() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"pue": 1.1, "commuteMilesOneWay": 16.4}"#.utf8).write(to: url)
        #expect(SharedSettings.read(from: url) == .values(.init(grid: nil, pue: 1.1, commute: 16.4)))
    }

    @Test func writingKeepsOtherKeys() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"pue": 1.2, "futureKey": "kept"}"#.utf8).write(to: url)
        try SharedSettings.write(.init(grid: 473, pue: 1.1, commute: 16.4), to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("futureKey"))
        #expect(text.contains("16.4") && !text.contains("16.39"))
        #expect(text.contains("gridGramsPerKwh"))
        #expect(SharedSettings.read(from: url) == .values(.init(grid: 473, pue: 1.1, commute: 16.4)))
    }

    @Test func brokenOrOutOfRangeFilesAreInvalid() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: url)
        #expect(SharedSettings.read(from: url) == .invalid)
        try Data(#"{"pue": 0.4}"#.utf8).write(to: url)
        #expect(SharedSettings.read(from: url) == .invalid)
    }
}
