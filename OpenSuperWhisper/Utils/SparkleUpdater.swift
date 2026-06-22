import Foundation
import Sparkle

/// Thin wrapper around Sparkle's standard updater. Sparkle reads `SUFeedURL` and `SUPublicEDKey`
/// from Info.plist, fetches the appcast, and performs verified in-place download + install.
@MainActor
final class SparkleUpdater {
    static let shared = SparkleUpdater()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Manual check — shows Sparkle's UI (up-to-date, or the update prompt).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
