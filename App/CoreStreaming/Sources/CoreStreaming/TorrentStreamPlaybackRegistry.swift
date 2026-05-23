import AVFoundation
import CoreStorage
import Foundation

/// Registered torrent byte source for `AVAssetResourceLoader` (FINDINGS Tier 3).
@MainActor
public final class TorrentStreamPlaybackRegistry {
    public static let shared = TorrentStreamPlaybackRegistry()

    private struct Entry {
        let delegate: TorrentStreamResourceLoader
        let playbackURL: URL
    }

    private var entries: [UUID: Entry] = [:]

    private init() {}

    public struct Registration: Sendable {
        public let id: UUID
        public let playbackURL: URL
    }

    public func register(
        pieceStore: PieceStore,
        streamTarget: TorrentStreamTarget,
        pieceManager: PieceManager,
        onPlayerRead: @escaping @Sendable (Int64, Int) async -> Void
    ) -> Registration {
        let id = UUID()
        let delegate = TorrentStreamResourceLoader(
            pieceStore: pieceStore,
            streamTarget: streamTarget,
            pieceManager: pieceManager,
            onPlayerRead: onPlayerRead
        )
        let url = URL(string: "mbtorrent://\(id.uuidString.lowercased())/stream.mp4")!
        entries[id] = Entry(delegate: delegate, playbackURL: url)
        TorrentLog.info("[Streaming] resource loader registered — \(MovieBoxFileLogger.redactURL(url))")
        return Registration(id: id, playbackURL: url)
    }

    public func unregister(id: UUID) {
        entries.removeValue(forKey: id)?.delegate.invalidate()
    }

    public func resourceLoader(for playbackURL: URL) -> TorrentStreamResourceLoader? {
        guard playbackURL.scheme == "mbtorrent",
              let host = playbackURL.host,
              let id = UUID(uuidString: host)
        else { return nil }
        return entries[id]?.delegate
    }

    public func playbackURL(for id: UUID) -> URL? {
        entries[id]?.playbackURL
    }
}
