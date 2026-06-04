import AppKit
import CoreStreaming
import MovieBoxCore

/// Flushes in-flight download state when the user quits, hides the app, or backgrounds it.
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var appServices: AppServices?

    func applicationWillTerminate(_ notification: Notification) {
        flushDownloadsSynchronously()
    }

    func applicationDidResignActive(_ notification: Notification) {
        flushDownloadsInBackground()
    }

    func applicationWillHide(_ notification: Notification) {
        flushDownloadsInBackground()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if StreamFileLocator.isMovieBoxStreamFile(url) {
                NotificationCenter.default.post(name: .movieBoxOpenStreamFile, object: url)
            } else {
                NotificationCenter.default.post(name: .movieBoxOpenImportURL, object: url)
            }
        }
    }

    private func flushDownloadsInBackground() {
        guard let appServices else { return }
        Task { @MainActor in
            await appServices.downloadManager.flushPersistenceForTermination()
        }
    }

    private func flushDownloadsSynchronously() {
        guard let appServices else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await appServices.downloadManager.flushPersistenceForTermination()
            appServices.finishStreamCleanup()
            _ = StorageCleanup.runMaintenance(streamBufferMaxAge: 0)
            DockDownloadPresenter.clear()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2.5)
    }
}
