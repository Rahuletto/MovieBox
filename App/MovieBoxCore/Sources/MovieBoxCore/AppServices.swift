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
    private var pendingStreamCleanup: (infoHash: String, movieId: Int)?
    public private(set) var activeDownloadPlaybackTaskId: UUID?
    public private(set) var activeStreamFilePlaybackHash: String?

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
        await endActiveDownloadPlayback()
        await persistentPlayback.cancel(appServices: self)
        finishStreamCleanup()
    }

    public func endActiveDownloadPlayback() async {
        if let taskId = activeDownloadPlaybackTaskId {
            activeDownloadPlaybackTaskId = nil
            await downloadManager.endPlaybackSession(for: taskId)
        }
        if let hash = activeStreamFilePlaybackHash {
            activeStreamFilePlaybackHash = nil
            await downloadManager.endStreamFilePlayback(infoHash: hash)
        }
        await playbackCoordinator.cancel()
    }

    /// Plays a `.moviebox_*.stream` sidecar (e.g. Finder double-click).
    public func playStreamFile(at url: URL, playerState: PlayerState) async throws {
        await cancelActiveStreamWithoutPersistentReset()
        await streamingOrchestrator.stop()

        let start = try await downloadManager.beginPlaybackFromStreamFile(at: url)
        if let taskId = start.downloadTaskId {
            activeDownloadPlaybackTaskId = taskId
            activeStreamFilePlaybackHash = nil
        } else {
            activeStreamFilePlaybackHash = start.infoHash
            activeDownloadPlaybackTaskId = nil
        }

        let torrent = StreamFilePlaybackSupport.torrentResult(
            displayTitle: start.displayTitle,
            metadata: start.metadata
        )
        let coordinator = beginPlaybackCoordinator()
        try await coordinator.playInProgressDownload(
            session: start.session,
            torrent: torrent,
            allTorrents: [torrent],
            playerState: playerState,
            movieId: 0,
            subtitleURL: nil,
            knownDurationSeconds: Double(start.metadata.totalSize)
        )
        playerState.isStreamingTorrent = true
    }

    /// Stops torrent engine/session without clearing persistent pill state (used internally during replace).
    func cancelActiveStreamWithoutPersistentReset() async {
        await activeSession?.cancel()
        activeSession = nil
        await playbackCoordinator.cancel()
    }

    public func trackStreamForCleanup(torrent: TorrentResult, movieId: Int) {
        guard let hash = torrent.resolvedInfoHash, movieId > 0 else { return }
        pendingStreamCleanup = (hash.lowercased(), movieId)
    }

    public func finishStreamCleanup(hlsCacheKey: String? = nil) {
        guard let pending = pendingStreamCleanup else { return }
        _ = StorageCleanup.cleanupAfterStream(
            infoHash: pending.infoHash,
            movieId: pending.movieId,
            hlsCacheKey: hlsCacheKey
        )
        pendingStreamCleanup = nil
    }

    public func runStartupStorageCleanup() {
        Task.detached(priority: .utility) {
            _ = StorageCleanup.runMaintenance(
                retainStreamInfoHashes: [],
                streamBufferMaxAge: 0
            )
        }
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

    public var hasActiveTorrentSession: Bool {
        activeSession != nil || activeDownloadPlaybackTaskId != nil
    }

    /// Stops any active torrent stream engine without cancelling an in-flight playback pipeline task.
    public func prepareForLocalFilePlayback() async {
        await endActiveDownloadPlayback()
        guard hasActiveTorrentSession else { return }
        finishStreamCleanup()
        await activeSession?.cancel()
        activeSession = nil
        await streamingOrchestrator.stop()
        await playbackCoordinator.cancel()
    }

    public func playInProgressDownload(
        task: DownloadManager.DownloadTask,
        torrent: TorrentResult,
        allTorrents: [TorrentResult],
        playerState: PlayerState,
        movieId: Int,
        subtitleURL: URL?,
        subtitleAppearance: SubtitleAppearance,
        subtitleFontSize: CGFloat,
        displayTitle: String?,
        resumePosition: Double?,
        posterURL: URL?
    ) async throws {
        await cancelActiveStreamWithoutPersistentReset()
        await streamingOrchestrator.stop()
        let session = try await downloadManager.beginPlaybackSession(for: task.id)
        activeDownloadPlaybackTaskId = task.id
        try await playbackCoordinator.playInProgressDownload(
            session: session,
            torrent: torrent,
            allTorrents: allTorrents,
            playerState: playerState,
            movieId: movieId,
            subtitleURL: subtitleURL,
            subtitleAppearance: subtitleAppearance,
            subtitleFontSize: subtitleFontSize,
            displayTitle: displayTitle,
            resumePosition: resumePosition,
            knownDurationSeconds: task.totalBytes > 0 ? Double(task.totalBytes) : nil,
            posterURL: posterURL
        )
        playerState.isStreamingTorrent = true
    }

    public func resolvedCompletedMediaPath(
        for torrent: TorrentResult,
        downloadRecords: [DownloadRecord] = []
    ) -> String? {
        DownloadPlaybackPaths.completedMediaPath(
            for: torrent,
            persistence: downloadPersistence,
            downloadManager: downloadManager,
            downloadRecords: downloadRecords
        )
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
