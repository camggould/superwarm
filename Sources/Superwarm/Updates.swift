import AppKit
import Observation
import Sparkle

/// In-app updates through Sparkle. Updates are EdDSA-signed release archives
/// listed in the appcast attached to the latest GitHub release.
///
/// Superwarm is a menu bar app with no Dock icon, so scheduled checks use
/// Sparkle's "gentle reminders": instead of a window popping up over whatever
/// you're doing, the popover shows an "Update available" button.
@MainActor
@Observable
final class Updates: NSObject, SPUStandardUserDriverDelegate {
    /// True when a scheduled check found an update the user hasn't looked at yet.
    private(set) var updateAvailable = false
    private(set) var availableVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    /// Updates only work from a bundled, configured app, not `swift run`.
    var isEnabled: Bool { controller != nil }

    var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    override init() {
        super.init()
        let bundled = Bundle.main.bundleURL.pathExtension == "app"
        let configured = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        guard bundled && configured else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Only interrupt if the user is already looking at Superwarm.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        let userInitiated = state.userInitiated
        Task { @MainActor in
            self.availableVersion = version
            if !handleShowingUpdate && !userInitiated { self.updateAvailable = true }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.updateAvailable = false }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.updateAvailable = false }
    }
}
