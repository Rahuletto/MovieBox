import CoreMetadata
import CoreTorrent
import Foundation
import MovieBoxCore

/// Torrent search results for How to Watch — memory + on-device cache across navigation and app restarts.
@MainActor
public enum MovieDetailTorrentCache {
    public struct Entry: Sendable {
        public let torrents: [TorrentResult]
        public let diagnostics: TorrentSearchDiagnostics?

        public init(torrents: [TorrentResult], diagnostics: TorrentSearchDiagnostics?) {
            self.torrents = torrents
            self.diagnostics = diagnostics
        }
    }

    private static var memoryStore: [String: Entry] = [:]

    public static func key(movieId: Int, kind: MediaKind, episode: TVEpisode?) -> String {
        if kind == .tv, let episode {
            return "tv:\(movieId):\(episode.seasonNumber):\(episode.episodeNumber)"
        }
        return "\(kind.rawValue):\(movieId)"
    }

    public static func entry(for key: String, indexerFingerprint: String) -> Entry? {
        if let cached = memoryStore[key] {
            return cached
        }
        guard let disk = PlaybackDiskCache.loadTorrentList(
            key: key,
            indexerFingerprint: indexerFingerprint
        ) else {
            return nil
        }
        let entry = Entry(torrents: disk.torrents, diagnostics: disk.diagnostics)
        memoryStore[key] = entry
        return entry
    }

    public static func store(
        key: String,
        indexerFingerprint: String,
        torrents: [TorrentResult],
        diagnostics: TorrentSearchDiagnostics?
    ) {
        guard !torrents.isEmpty else { return }
        let entry = Entry(torrents: torrents, diagnostics: diagnostics)
        memoryStore[key] = entry
        PlaybackDiskCache.saveTorrentList(
            key: key,
            indexerFingerprint: indexerFingerprint,
            torrents: torrents,
            diagnostics: diagnostics
        )
    }

    public static func remove(key: String) {
        memoryStore.removeValue(forKey: key)
        PlaybackDiskCache.removeTorrentList(key: key)
    }

    public static func clear(movieId: Int, kind: MediaKind) {
        let prefix = kind == .tv ? "tv:\(movieId):" : "\(kind.rawValue):\(movieId)"
        memoryStore.keys.filter { $0.hasPrefix(prefix) }.forEach { key in
            memoryStore.removeValue(forKey: key)
            PlaybackDiskCache.removeTorrentList(key: key)
        }
    }
}
