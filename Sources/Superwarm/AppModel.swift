import Foundation
import Observation
import SuperwarmKit

/// Grid intensity presets offered in Settings.
enum GridPreset: String, CaseIterable, Codable, Identifiable {
    case usAverage, worldAverage, lowCarbon, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .usAverage: "US average grid (EPA eGRID)"
        case .worldAverage: "World average grid (Ember)"
        case .lowCarbon: "Low-carbon grid (hydro/nuclear-heavy)"
        case .custom: "Custom"
        }
    }

    var gramsCO2PerKWh: Double {
        switch self {
        case .usAverage, .custom: 373
        case .worldAverage: 473
        case .lowCarbon: 50
        }
    }
}

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

    var gramsCO2PerKWh: Double { gridPreset == .custom ? customGramsPerKWh : gridPreset.gramsCO2PerKWh }

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

/// Where Superwarm keeps its own files on macOS.
enum AppPaths {
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Superwarm", isDirectory: true)
    }

    /// Read by the engine too (its default overrides path on macOS).
    static var modelOverrides: URL { supportDirectory.appendingPathComponent("models.json") }

    /// The Swift engine's cache from 0.1.x, superseded by the Rust engine's own
    /// cache in ~/Library/Caches/superwarm. Removed once to free ~15 MB.
    static func removeLegacyCache() {
        try? FileManager.default.removeItem(at: supportDirectory.appendingPathComponent("usage-cache.plist"))
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
            Task { await refresh() }
        }
    }

    private(set) var snapshot: Snapshot?
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    private(set) var engineError: String?

    @ObservationIgnored private let engine: Engine?
    @ObservationIgnored private let demo: Bool
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false

    init(autoRefresh: Bool = true, demo: Bool = false) {
        settings = AppSettings.load()
        engine = Engine.locate()
        self.demo = demo
        guard autoRefresh else { return }
        AppPaths.removeLegacyCache()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Runs the engine with the current settings and replaces the snapshot.
    func refresh() async {
        guard !isScanning else {
            refreshAgain = true  // settings changed mid-run: run once more after
            return
        }
        guard let engine else {
            engineError = EngineError.notFound.description
            return
        }
        isScanning = true
        defer { isScanning = false }
        repeat {
            refreshAgain = false
            let options = EngineOptions(
                gramsCO2PerKWh: settings.gramsCO2PerKWh,
                pue: settings.pue,
                commuteMilesOneWay: settings.commuteMilesOneWay,
                demo: demo
            )
            do {
                snapshot = try await Task.detached(priority: .userInitiated) { try engine.snapshot(options) }.value
                engineError = nil
            } catch {
                engineError = "\(error)"
            }
            lastScan = Date()
        } while refreshAgain
    }

    // MARK: Derived values for the views

    var current: PeriodSnapshot? { snapshot?.period(period) }

    var issues: [String] { (engineError.map { [$0] } ?? []) + (snapshot?.scan.issues ?? []) }

    var filesFound: Int { snapshot?.scan.filesFound ?? 0 }

    var menuBarTitle: String? {
        guard let snapshot else { return nil }
        switch settings.menuBarPeriod {
        case .today: return snapshot.period(.today).map { Format.grams($0.summary.footprint.co2Grams.central) }
        case .week: return snapshot.period(.week).map { Format.grams($0.summary.footprint.co2Grams.central) }
        case .iconOnly: return nil
        }
    }
}
