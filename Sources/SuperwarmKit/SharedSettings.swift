import Foundation

/// `settings.json` in the engine's config folder (engine/src/settings.rs).
/// Keys the app doesn't know are preserved when it writes.
public enum SharedSettings {
    public struct Values: Equatable, Sendable {
        public var grid: Double?
        public var pue: Double?
        public var commute: Double?

        public init(grid: Double? = nil, pue: Double? = nil, commute: Double? = nil) {
            self.grid = grid
            self.pue = pue
            self.commute = commute
        }
    }

    public enum ReadResult: Equatable, Sendable {
        case missing, invalid
        case values(Values)
    }

    // The ranges `superwarm settings` validates against.
    public static let gridRange = 0.0...2000.0
    public static let pueRange = 1.0...3.0
    public static let commuteRange = 0.1...500.0

    public static func read(from url: URL) -> ReadResult {
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? .invalid : .missing
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .invalid }
        let number = { (key: String) in (object[key] as? NSNumber)?.doubleValue }
        let values = Values(grid: number("gridGramsPerKwh"), pue: number("pue"), commute: number("commuteMilesOneWay"))
        let inRange = (values.grid.map(gridRange.contains) ?? true)
            && (values.pue.map(pueRange.contains) ?? true)
            && (values.commute.map { $0 > 0 && $0 <= commuteRange.upperBound } ?? true)
        return inRange ? .values(values) : .invalid
    }

    public static func write(_ values: Values, to url: URL) throws {
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        // Through the shortest decimal ("16.4"), or JSONSerialization writes 16.399999999999999.
        let decimal = { (value: Double?) in value.map { NSDecimalNumber(string: "\($0)") } }
        object["gridGramsPerKwh"] = decimal(values.grid)
        object["pue"] = decimal(values.pue)
        object["commuteMilesOneWay"] = decimal(values.commute)
        if case .values(let current) = read(from: url), current == values { return }  // unchanged: leave the file alone
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }
}
