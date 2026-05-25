import AppKit
import CoreStreaming
import MovieBoxCore

/// Flushes in-flight download state when the user quits or logs out.
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var appServices: AppServices?

    func applicationWillTerminate(_ notification: Notification) {
        guard let appServices else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await appServices.downloadManager.flushPersistenceForTermination()
            DockDownloadPresenter.clear()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2.5)
    }
}
