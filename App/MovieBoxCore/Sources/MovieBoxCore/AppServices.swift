import CoreStreaming
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
}
