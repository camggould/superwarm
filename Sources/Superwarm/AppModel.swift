import Foundation
import Observation
import SuperwarmCore

/// User preferences, persisted as JSON in UserDefaults.
struct AppSettings: Codable, Equatable {
    var gridPreset: GridPreset = .usAverage
    var customGramsPerKWh: Double = 373
    var pue: Double = 1.15
    var commuteMilesOneWay: Double = 11.7
    var menuBarPeriod: MenuBarPeriod = .today

    enum MenuBarPeriod: String, Codable, CaseIterable, Identifiable {
        case today, week, iconOnly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .today: "Today's CO₂e"
            case .week: "Last 7 days' CO₂e"
            case .iconOnly: "Icon only"
            }
        }
    }

    var grid: GridSettings {
        GridSettings(
            gramsCO2PerKWh: gridPreset == .custom ? customGramsPerKWh : gridPreset.gramsCO2PerKWh,
            pue: pue
        )
    }

    var equivalents: EquivalentSettings { EquivalentSettings(commuteMilesOneWay: commuteMilesOneWay) }

    static let key = "settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Owns the on-disk cache and does the slow file work off the main actor.
actor ScanWorker {
    private var cache: ScanCache?

    func scan() -> ScanResult {
        var cache = self.cache ?? ScanCache.load()
        let result = UsageScanner().scan(cache: &cache)
        if result.filesParsed > 0 || self.cache == nil { try? cache.save() }
        self.cache = cache
        return result
    }
}

@MainActor
@Observable
final class AppModel {
    var period: Period = .today
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            Task { await rebuildReport() }
        }
    }

    private(set) var report: UsageReport?
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    private(set) var issues: [String] = []
    private(set) var filesFound = 0

    private var records: [UsageRecord] = []
    private let worker = ScanWorker()
    private var refreshLoop: Task<Void, Never>?

    init() {
        settings = AppSettings.load()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let result = await worker.scan()
        records = result.records
        issues = result.issues
        filesFound = result.filesFound
        lastScan = Date()
        await rebuildReport()
    }

    func rebuildReport() async {
        let records = self.records
        let model = EmissionsModel(grid: settings.grid)
        let overrides = ModelOverride.load()
        report = await Task.detached(priority: .userInitiated) {
            UsageReport(records: records, model: model, overrides: overrides)
        }.value
    }

    // MARK: Derived values for the views

    var interval: DateInterval? { period.interval() }

    var summary: Summary { report?.summary(in: interval) ?? Summary() }

    var menuBarTitle: String? {
        guard let report else { return nil }
        switch settings.menuBarPeriod {
        case .today: return Format.grams(report.summary(in: Period.today.interval()).footprint.co2Grams.central)
        case .week: return Format.grams(report.summary(in: Period.week.interval()).footprint.co2Grams.central)
        case .iconOnly: return nil
        }
    }
}
