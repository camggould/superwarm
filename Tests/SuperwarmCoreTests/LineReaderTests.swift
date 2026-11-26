import Foundation
import Testing
@testable import SuperwarmCore

@Suite struct LineReaderTests {
    @Test func filtersByNeedle() throws {
        var seen: [String] = []
        try LineReader.forEachLine(in: Data("a usage\nb\n\nc usage".utf8), containingAny: [Data("usage".utf8)]) {
            seen.append(String(decoding: $0, as: UTF8.self))
        }
        #expect(seen == ["a usage", "c usage"])
    }

    @Test func readsZstdWhenAvailable() throws {
        guard let zstd = LineReader.zstdPath else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plain = dir.appendingPathComponent("r.jsonl")
        try "one\ntwo\n".write(to: plain, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-q", plain.path, "-o", plain.path + ".zst"]
        try process.run()
        process.waitUntilExit()

        var lines: [String] = []
        try LineReader.forEachLine(in: URL(fileURLWithPath: plain.path + ".zst")) { lines.append(String(decoding: $0, as: UTF8.self)) }
        #expect(lines == ["one", "two"])
    }
}
