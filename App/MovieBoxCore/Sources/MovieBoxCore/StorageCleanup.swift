import CoreStreaming
import Foundation

/// Reclaims disk from transient playback/stream caches (not completed downloads in ~/Movies).
public enum StorageCleanup {
    public struct Report: Sendable {
        public let freedBytes: Int64
        public let removedStreamSessions: Int
        public let removedPlaybackCacheFiles: Int
        public let removedHLSDirectories: Int

        public init(
            freedBytes: Int64 = 0,
            removedStreamSessions: Int = 0,
            removedPlaybackCacheFiles: Int = 0,
            removedHLSDirectories: Int = 0
        ) {
            self.freedBytes = freedBytes
            self.removedStreamSessions = removedStreamSessions
            self.removedPlaybackCacheFiles = removedPlaybackCacheFiles
            self.removedHLSDirectories = removedHLSDirectories
        }

        public static func + (lhs: Report, rhs: Report) -> Report {
            Report(
                freedBytes: lhs.freedBytes + rhs.freedBytes,
                removedStreamSessions: lhs.removedStreamSessions + rhs.removedStreamSessions,
                removedPlaybackCacheFiles: lhs.removedPlaybackCacheFiles + rhs.removedPlaybackCacheFiles,
                removedHLSDirectories: lhs.removedHLSDirectories + rhs.removedHLSDirectories
            )
        }
    }

    /// After playback/stream ends — drop large sparse files and scrubber JSON for that torrent.
    public static func cleanupAfterStream(
        infoHash: String?,
        movieId: Int? = nil,
        hlsCacheKey: String? = nil
    ) -> Report {
        var freedBytes: Int64 = 0
        var removedStreamSessions = 0
        var removedPlaybackCacheFiles = 0
        var removedHLSDirectories = 0

        if let infoHash, !infoHash.isEmpty {
            freedBytes += StreamSessionDiskStore.purgeSession(infoHash: infoHash)
            removedStreamSessions += 1
            if let movieId, movieId > 0 {
                PlaybackDiskCache.removeStreamBuffer(tmdbId: movieId, infoHash: infoHash)
                removedPlaybackCacheFiles += 1
            }
        }
        if let hlsCacheKey, !hlsCacheKey.isEmpty {
            let hls = purgeHLSCacheEntry(cacheKey: hlsCacheKey)
            freedBytes += hls.freedBytes
            removedHLSDirectories += hls.removedHLSDirectories
        }
        return Report(
            freedBytes: freedBytes,
            removedStreamSessions: removedStreamSessions,
            removedPlaybackCacheFiles: removedPlaybackCacheFiles,
            removedHLSDirectories: removedHLSDirectories
        )
    }

    /// Launch / periodic — TTL sweeps and delete orphan stream data.
    public static func runMaintenance(
        retainStreamInfoHashes: Set<String> = [],
        torrentListMaxAge: TimeInterval = PlaybackDiskCache.defaultTorrentListTTL,
        streamBufferMaxAge: TimeInterval = 0,
        hlsMaxAge: TimeInterval = 4 * 60 * 60,
        maxTorrentListFiles: Int = 40
    ) -> Report {
        var freedBytes = StreamSessionDiskStore.purgeLegacyTemporaryStore()
        let streamFreed = StreamSessionDiskStore.purgeAllSessions(retaining: retainStreamInfoHashes)
        freedBytes += streamFreed
        var removedStreamSessions = streamFreed > 0 ? 1 : 0

        let cacheSweep = PlaybackDiskCache.sweep(
            torrentListMaxAge: torrentListMaxAge,
            streamBufferMaxAge: streamBufferMaxAge,
            maxTorrentListFiles: maxTorrentListFiles
        )
        freedBytes += cacheSweep.freedBytes
        var removedPlaybackCacheFiles = cacheSweep.removedFiles

        let hls = pruneHLSCache(maxAge: hlsMaxAge, exceptCacheKey: nil)
        freedBytes += hls.freedBytes
        let removedHLSDirectories = hls.removedHLSDirectories

        let report = Report(
            freedBytes: freedBytes,
            removedStreamSessions: removedStreamSessions,
            removedPlaybackCacheFiles: removedPlaybackCacheFiles,
            removedHLSDirectories: removedHLSDirectories
        )
        if report.freedBytes > 0 {
            NSLog(
                "MovieBox storage cleanup — freed \(report.freedBytes / 1024 / 1024) MB " +
                "(streams=\(report.removedStreamSessions) cacheFiles=\(report.removedPlaybackCacheFiles) hls=\(report.removedHLSDirectories))"
            )
        }
        return report
    }

    // MARK: - HLS remux cache (Library/Caches/com.marban.MovieBox/HLS)

    private static func hlsRootDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.marban.MovieBox", isDirectory: true)
            .appendingPathComponent("HLS", isDirectory: true)
    }

    @discardableResult
    public static func purgeHLSCacheEntry(cacheKey: String) -> Report {
        guard let root = hlsRootDirectory() else { return Report() }
        let safe = cacheKey.replacingOccurrences(of: "/", with: "_")
        let directory = root.appendingPathComponent(safe, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return Report() }
        let bytes = StreamSessionDiskStore.directoryAllocatedBytes(directory)
        try? FileManager.default.removeItem(at: directory)
        return Report(freedBytes: bytes, removedHLSDirectories: 1)
    }

    @discardableResult
    public static func pruneHLSCache(maxAge: TimeInterval, exceptCacheKey: String?) -> Report {
        guard let root = hlsRootDirectory(),
              FileManager.default.fileExists(atPath: root.path),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: root,
                  includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                  options: [.skipsHiddenFiles]
              )
        else { return Report() }

        let keep = exceptCacheKey.map {
            $0.replacingOccurrences(of: "/", with: "_").lowercased()
        }
        let now = Date()
        var freedBytes: Int64 = 0
        var removedHLSDirectories = 0
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if entry.lastPathComponent.lowercased() == keep { continue }
            let age: TimeInterval
            if let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate {
                age = now.timeIntervalSince(modified)
            } else {
                age = .infinity
            }
            guard age >= maxAge else { continue }
            freedBytes += StreamSessionDiskStore.directoryAllocatedBytes(entry)
            try? FileManager.default.removeItem(at: entry)
            removedHLSDirectories += 1
        }
        return Report(freedBytes: freedBytes, removedHLSDirectories: removedHLSDirectories)
    }
}
