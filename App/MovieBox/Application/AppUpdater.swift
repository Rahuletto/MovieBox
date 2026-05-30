import Foundation
import Sparkle

/// Sparkle-based auto-update controller (GitHub Releases → appcast.xml).
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    /// Appcast served from the repo; updated by the release workflow after each GitHub Release.
    static let feedURL = URL(string: "https://raw.githubusercontent.com/Rahuletto/moviebox/main/appcast.xml")!

    static let releasesPage = URL(string: "https://github.com/Rahuletto/moviebox/releases")!

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater { controller.updater }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

enum AppVersion {
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    static var display: String {
        "\(marketing) (\(build))"
    }
}
