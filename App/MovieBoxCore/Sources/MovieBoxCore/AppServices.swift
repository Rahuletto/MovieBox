import CoreStorage
import CoreStreaming
import CoreTorrent
import Foundation
import MoviePlayerKit
import Observation

@MainActor
@Observable
public final class AppServices {
    public let downloadManager: DownloadManager
    public let moviePlayerSession = MoviePlayerSession()
    public private(set) var playbackCoordinator: TorrentPlaybackCoordinator
    public private(set) var activeSession: TorrentStreamSession?
    public let persistentPlayback = PersistentPlaybackController()
    public var downloadPersistence: DownloadPersistenceService?

    public let streamingOrchestrator: StreamingOrchestrator

    public init(downloadDirectory: URL? = nil) {
        self.streamingOrchestrator = StreamingOrchestrator()
        self.downloadManager = DownloadManager(downloadDirectory: downloadDirectory)
        self.playbackCoordinator = TorrentPlaybackCoordinator(
            orchestrator: streamingOrchestrator,
            moviePlayer: moviePlayerSession
        )
    }

    public func cancelActiveStream() async {
        await persistentPlayback.cancel(appServices: self)
    }

    /// Stops torrent engine/session without clearing persistent pill state (used internally during replace).
    func cancelActiveStreamWithoutPersistentReset() async {
        await activeSession?.cancel()
        activeSession = nil
        await playbackCoordinator.cancel()
    }

    @discardableResult
    public func beginPlaybackCoordinator() -> TorrentPlaybackCoordinator {
        playbackCoordinator = TorrentPlaybackCoordinator(
            orchestrator: streamingOrchestrator,
            moviePlayer: moviePlayerSession
        )
        playbackCoordinator.downloadPersistence = downloadPersistence
        return playbackCoordinator
    }

    public func syncPlaybackPolicy(from settings: AppSettings) {
        playbackCoordinator.strictHDRValidation = settings.strictHDRValidation
        moviePlayerSession.allowTranscodeFallback = settings.allowTranscodeFallback
    }

    /// Applies Settings → Downloads folder (security-scoped bookmark + writable probe).
    @discardableResult
    public func applyDownloadDirectory(from settings: AppSettings) -> URL {
        let preferred = DownloadStorage.resolveRootDirectory(path: settings.defaultDownloadPath)
        if DownloadFolderAccess.beginAccess(to: preferred) {
            do {
                try downloadManager.configureDownloadRoot(preferred)
                NSLog("MovieBox: download folder — %@", preferred.path)
                return preferred
            } catch {
                NSLog(
                    "MovieBox: download folder unavailable at %@ — %@",
                    preferred.path,
                    error.localizedDescription
                )
            }
        } else if DownloadStorage.isRunningInAppSandbox {
            NSLog(
                "MovieBox: no folder access for %@ — use Settings → Downloads → Choose…",
                preferred.path
            )
        }

        DownloadFolderAccess.deactivate()
        let fallback = DownloadStorage.sandboxDownloadsRootDirectory()
        _ = DownloadFolderAccess.beginAccess(to: fallback)
        do {
            try downloadManager.configureDownloadRoot(fallback)
            NSLog("MovieBox: using sandbox Downloads folder — %@", fallback.path)
            return fallback
        } catch {
            NSLog("MovieBox: fallback download folder failed — %@", error.localizedDescription)
            return fallback
        }
    }

    public func registerActiveSession(_ session: TorrentStreamSession?) {
        activeSession = session
    }

    /// Warms torrent metadata cache for the best release while the user is on the detail page.
    public func prewarmStreamingMetadata(for torrents: [TorrentResult]) {
        let candidates = torrents.filter { $0.seeders > 0 }
        let ordered = (candidates.isEmpty ? torrents : candidates).sorted { $0.seeders > $1.seeders }
        guard let torrent = ordered.first else { return }
        guard let identity = DownloadIdentity.resolve(
            magnetURI: torrent.magnetURI,
            storedInfoHash: torrent.infoHash
        ) else { return }
        TorrentMetadataFetcher.prewarm(
            infoHash: identity.infoHash,
            magnetTrackers: identity.magnetTrackers
        )
    }
}
