import AVFoundation
import CoreStorage
import Foundation

/// Custom scheme for AVAssetResourceLoader (must not be http/https; `https` suffix per Jared Sinclair).
public enum TorrentPlaybackURLScheme {
  public static let active = "mbtorrenthttps"
  public static let legacy = "mbtorrent"

  public static func playbackURL(registrationID: UUID) -> URL {
    URL(string: "\(active)://\(registrationID.uuidString.lowercased())/stream.mp4")!
  }

  public static func isTorrentPlayback(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == active || scheme == legacy
  }

  public static func registrationID(from url: URL) -> UUID? {
    guard isTorrentPlayback(url), let host = url.host else { return nil }
    return UUID(uuidString: host)
  }
}

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
        let url = TorrentPlaybackURLScheme.playbackURL(registrationID: id)
        entries[id] = Entry(delegate: delegate, playbackURL: url)
        TorrentLog.info("[Streaming] resource loader registered — \(MovieBoxFileLogger.redactURL(url))")
        return Registration(id: id, playbackURL: url)
    }

    public func unregister(id: UUID) {
        entries.removeValue(forKey: id)?.delegate.invalidate()
    }

    public func resourceLoader(for playbackURL: URL) -> TorrentStreamResourceLoader? {
        guard let id = TorrentPlaybackURLScheme.registrationID(from: playbackURL) else { return nil }
        return entries[id]?.delegate
    }

    public func playbackURL(for id: UUID) -> URL? {
        entries[id]?.playbackURL
    }
}
