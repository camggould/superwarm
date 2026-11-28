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

/// User preferences. The estimate settings (grid, PUE, commute) are shared with
/// the CLI through `settings.json`; the rest are app-only, in UserDefaults.
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

    /// The app's preferences with the shared file's values on top, so a change
    /// made with `superwarm settings` shows up here. The first launch after an
    /// update copies the app's existing values into the shared file.
    static func load() -> AppSettings {
        let stored = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
        var settings = stored ?? AppSettings()
        switch SharedSettings.read(from: AppPaths.sharedSettings) {
        case .values(let shared): settings.apply(shared)
        case .missing: if stored != nil { settings.writeShared() }
        case .invalid: settings.writeShared()  // the CLI would refuse it too; repair it
        }
        return settings.clamped()
    }

    func save() {
        saveLocal()
        writeShared()
    }

    /// The app's own copy only: used when the change came from the shared file.
    func saveLocal() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    private func writeShared() {
        try? SharedSettings.write(.init(grid: gramsCO2PerKWh, pue: pue, commute: commuteMilesOneWay), to: AppPaths.sharedSettings)
    }

    /// Takes the shared values, mapping a grid intensity back to its preset.
    mutating func apply(_ shared: SharedSettings.Values) {
        if let pue = shared.pue { self.pue = pue }
        if let commute = shared.commute { commuteMilesOneWay = commute }
        if let grid = shared.grid, grid != gramsCO2PerKWh {
            if let preset = GridPreset.allCases.first(where: { $0 != .custom && $0.gramsCO2PerKWh == grid }) {
                gridPreset = preset
            } else {
                gridPreset = .custom
                customGramsPerKWh = grid
            }
        }
    }

    /// Within the ranges the engine accepts, so a stray value typed in Settings can't stop it.
    func clamped() -> AppSettings {
        var s = self
        s.customGramsPerKWh = min(max(customGramsPerKWh, SharedSettings.gridRange.lowerBound), SharedSettings.gridRange.upperBound)
        s.pue = min(max(pue, SharedSettings.pueRange.lowerBound), SharedSettings.pueRange.upperBound)
        s.commuteMilesOneWay = min(max(commuteMilesOneWay, SharedSettings.commuteRange.lowerBound), SharedSettings.commuteRange.upperBound)
        return s
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

    /// Estimate settings shared with the CLI (`superwarm settings`).
    static var sharedSettings: URL { supportDirectory.appendingPathComponent("settings.json") }

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
            // Never assign `settings` in here: with @Observable that re-enters
            // the setter (and this observer) until the stack overflows.
            guard settings != oldValue else { return }
            if applyingSharedSettings {
                settings.clamped().saveLocal()  // the loop's next refresh uses the new values
                return
            }
            settings.clamped().save()
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
    @ObservationIgnored private var lastRemoteSync: Date?
    @ObservationIgnored private var syncRequested = false
    @ObservationIgnored private var applyingSharedSettings = false

    /// Remote machines are pulled over SSH at most this often (and on demand).
    static let remoteSyncInterval: TimeInterval = 15 * 60

    init(autoRefresh: Bool = true, demo: Bool = false) {
        settings = AppSettings.load()
        engine = Engine.locate()
        self.demo = demo
        guard autoRefresh else { return }
        AppPaths.removeLegacyCache()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                self?.reloadSharedSettings()
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Picks up changes made with `superwarm settings` (the refresh that follows uses them).
    private func reloadSharedSettings() {
        let fresh = AppSettings.load()
        guard fresh != settings else { return }
        applyingSharedSettings = true
        settings = fresh
        applyingSharedSettings = false
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
            let syncDue = lastRemoteSync.map { Date().timeIntervalSince($0) > Self.remoteSyncInterval } ?? true
            let sync = !demo && (syncRequested || syncDue)
            syncRequested = false
            let values = settings.clamped()  // a half-typed value in Settings can't stop the engine
            let options = EngineOptions(
                gramsCO2PerKWh: values.gramsCO2PerKWh,
                pue: values.pue,
                commuteMilesOneWay: values.commuteMilesOneWay,
                demo: demo,
                sync: sync
            )
            do {
                snapshot = try await Task.detached(priority: .userInitiated) { try engine.snapshot(options) }.value
                engineError = nil
                if sync { lastRemoteSync = Date() }
            } catch {
                engineError = "\(error)"
            }
            lastScan = Date()
        } while refreshAgain
    }

    // MARK: Remote machines

    /// Pulls new usage from remote machines now, instead of waiting for the next scheduled sync.
    func syncRemotes() async {
        syncRequested = true
        await refresh()
    }

    func addRemote(name: String, ssh: String) async throws {
        try await runEngine(["remote", "add", name, ssh])
        await syncRemotes()
    }

    func removeRemote(_ name: String) async throws {
        try await runEngine(["remote", "remove", name])
        await refresh()
    }

    private func runEngine(_ arguments: [String]) async throws {
        guard let engine else { throw EngineError.notFound }
        try await Task.detached(priority: .userInitiated) { try engine.run(arguments) }.value
    }

    // MARK: Derived values for the views

    var current: PeriodSnapshot? { snapshot?.period(period) }

    var issues: [String] {
        let remoteErrors = (snapshot?.remotes ?? []).compactMap { r in r.lastError.map { "\(r.name): \($0)" } }
        return (engineError.map { [$0] } ?? []) + (snapshot?.scan.issues ?? []) + remoteErrors
    }

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
