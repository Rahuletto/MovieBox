import CoreStreaming
import CoreTorrent
import Foundation
import Observation

@MainActor
@Observable
public final class AppServices {
    public let downloadManager: DownloadManager
    public private(set) var playbackCoordinator: TorrentPlaybackCoordinator
    public private(set) var activeSession: TorrentStreamSession?

    public let streamingOrchestrator: StreamingOrchestrator

    public init(downloadDirectory: URL? = nil) {
        self.streamingOrchestrator = StreamingOrchestrator()
        self.downloadManager = DownloadManager(downloadDirectory: downloadDirectory)
        self.playbackCoordinator = TorrentPlaybackCoordinator(orchestrator: streamingOrchestrator)
    }

    public func cancelActiveStream() async {
        await activeSession?.cancel()
        activeSession = nil
        await playbackCoordinator.cancel()
    }

    @discardableResult
    public func beginPlaybackCoordinator() -> TorrentPlaybackCoordinator {
        playbackCoordinator = TorrentPlaybackCoordinator(orchestrator: streamingOrchestrator)
        return playbackCoordinator
    }

    public func registerActiveSession(_ session: TorrentStreamSession?) {
        activeSession = session
    }

    /// Warms torrent metadata cache for the best release while the user is on the detail page.
    public func prewarmStreamingMetadata(for torrents: [TorrentResult]) {
        let candidates = torrents.filter { $0.seeders > 0 }
        let ordered = (candidates.isEmpty ? torrents : candidates).sorted { $0.seeders > $1.seeders }
        guard let torrent = ordered.first else { return }
        let magnet = MagnetURI(from: torrent.magnetURI)
        guard let infoHash = torrent.infoHash ?? magnet?.infoHash, !infoHash.isEmpty else { return }
        TorrentMetadataFetcher.prewarm(infoHash: infoHash, magnetTrackers: magnet?.trackers ?? [])
    }
}
