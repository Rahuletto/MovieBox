import Foundation

/// Keeps torrent engine + HTTP server alive for playback opened from a `.stream` file (no download task).
@MainActor
struct StreamFilePlaybackBundle {
    let infoHash: String
    let metadata: TorrentMetadata
    let displayTitle: String
    let store: PieceStore
    let manager: PieceManager
    let engine: TorrentEngine
    let session: DownloadPlaybackSession
}
