import Foundation

public struct StreamFilePlaybackStart: Sendable {
    public let session: DownloadPlaybackSession
    public let metadata: TorrentMetadata
    public let displayTitle: String
    public let infoHash: String
    /// Set when playback reuses an active download task's engine.
    public let downloadTaskId: UUID?

    public init(
        session: DownloadPlaybackSession,
        metadata: TorrentMetadata,
        displayTitle: String,
        infoHash: String,
        downloadTaskId: UUID?
    ) {
        self.session = session
        self.metadata = metadata
        self.displayTitle = displayTitle
        self.infoHash = infoHash
        self.downloadTaskId = downloadTaskId
    }
}
