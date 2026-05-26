import CoreTorrent
import Foundation

/// File-backed cache for torrent UI and stream scrubber state (Application Support).
public enum PlaybackDiskCache {
    public static let defaultTorrentListTTL: TimeInterval = 6 * 60 * 60

    private static let cacheFolderName = "playback-cache"
    private static let torrentListsFolder = "torrent-lists"
    private static let streamBuffersFolder = "stream-buffers"

    // MARK: - Torrent list (How to Watch)

    public struct TorrentListEntry: Sendable, Codable {
        public let savedAt: Date
        public let indexerFingerprint: String
        public let torrents: [TorrentResult]
        public let diagnostics: TorrentSearchDiagnosticsSnapshot?

        public init(
            savedAt: Date,
            indexerFingerprint: String,
            torrents: [TorrentResult],
            diagnostics: TorrentSearchDiagnosticsSnapshot?
        ) {
            self.savedAt = savedAt
            self.indexerFingerprint = indexerFingerprint
            self.torrents = torrents
            self.diagnostics = diagnostics
        }
    }

    public struct TorrentSearchDiagnosticsSnapshot: Sendable, Codable {
        public var queryUsed: String
        public var torrentioAttempted: Bool
        public var torrentioCount: Int
        public var torrentioError: String?
        public var ytsAttempted: Bool
        public var ytsCount: Int
        public var ytsError: String?
        public var nativeCounts: [String: Int]
        public var nativeErrors: [String: String]

        public init(from diagnostics: TorrentSearchDiagnostics) {
            queryUsed = diagnostics.queryUsed
            torrentioAttempted = diagnostics.torrentioAttempted
            torrentioCount = diagnostics.torrentioCount
            torrentioError = diagnostics.torrentioError
            ytsAttempted = diagnostics.ytsAttempted
            ytsCount = diagnostics.ytsCount
            ytsError = diagnostics.ytsError
            nativeCounts = diagnostics.nativeCounts
            nativeErrors = diagnostics.nativeErrors
        }

        public func makeDiagnostics() -> TorrentSearchDiagnostics {
            var value = TorrentSearchDiagnostics()
            value.queryUsed = queryUsed
            value.torrentioAttempted = torrentioAttempted
            value.torrentioCount = torrentioCount
            value.torrentioError = torrentioError
            value.ytsAttempted = ytsAttempted
            value.ytsCount = ytsCount
            value.ytsError = ytsError
            value.nativeCounts = nativeCounts
            value.nativeErrors = nativeErrors
            return value
        }
    }

    public static func indexerFingerprint(_ enabledIndexers: String?) -> String {
        let trimmed = (enabledIndexers ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "default" : trimmed
    }

    public static func saveTorrentList(
        key: String,
        indexerFingerprint: String,
        torrents: [TorrentResult],
        diagnostics: TorrentSearchDiagnostics?
    ) {
        guard !torrents.isEmpty else { return }
        let entry = TorrentListEntry(
            savedAt: Date(),
            indexerFingerprint: indexerFingerprint,
            torrents: torrents,
            diagnostics: diagnostics.map(TorrentSearchDiagnosticsSnapshot.init(from:))
        )
        writeJSON(entry, to: torrentListURL(for: key))
    }

    public static func loadTorrentList(
        key: String,
        indexerFingerprint: String,
        maxAge: TimeInterval = defaultTorrentListTTL
    ) -> (torrents: [TorrentResult], diagnostics: TorrentSearchDiagnostics?)? {
        guard let entry: TorrentListEntry = readJSON(from: torrentListURL(for: key)) else { return nil }
        guard entry.indexerFingerprint == indexerFingerprint else {
            try? FileManager.default.removeItem(at: torrentListURL(for: key))
            return nil
        }
        guard Date().timeIntervalSince(entry.savedAt) <= maxAge else {
            try? FileManager.default.removeItem(at: torrentListURL(for: key))
            return nil
        }
        guard !entry.torrents.isEmpty else { return nil }
        return (entry.torrents, entry.diagnostics?.makeDiagnostics())
    }

    public static func removeTorrentList(key: String) {
        try? FileManager.default.removeItem(at: torrentListURL(for: key))
    }

    // MARK: - Stream buffer ranges (scrubber grey bars)

    public struct StreamBufferSnapshot: Sendable, Codable {
        public let savedAt: Date
        public let tmdbId: Int
        public let infoHash: String
        public let durationSeconds: Double
        /// Pairs of `[lower, upper]` timeline seconds.
        public let ranges: [[Double]]

        public init(
            savedAt: Date,
            tmdbId: Int,
            infoHash: String,
            durationSeconds: Double,
            ranges: [ClosedRange<Double>]
        ) {
            self.savedAt = savedAt
            self.tmdbId = tmdbId
            self.infoHash = infoHash.lowercased()
            self.durationSeconds = durationSeconds
            self.ranges = ranges.map { [$0.lowerBound, $0.upperBound] }
        }

        public func timeRanges() -> [ClosedRange<Double>] {
            ranges.compactMap { pair in
                guard pair.count == 2, pair[1] > pair[0] else { return nil }
                return pair[0]...pair[1]
            }
        }
    }

    public static func streamBufferKey(tmdbId: Int, infoHash: String) -> String {
        "\(tmdbId)_\(infoHash.lowercased())"
    }

    public static func saveStreamBufferRanges(
        tmdbId: Int,
        infoHash: String,
        durationSeconds: Double,
        ranges: [ClosedRange<Double>]
    ) {
        let hash = infoHash.lowercased()
        guard tmdbId > 0, !hash.isEmpty, durationSeconds.isFinite, durationSeconds > 0, !ranges.isEmpty else {
            return
        }
        let snapshot = StreamBufferSnapshot(
            savedAt: Date(),
            tmdbId: tmdbId,
            infoHash: hash,
            durationSeconds: durationSeconds,
            ranges: ranges
        )
        writeJSON(snapshot, to: streamBufferURL(key: streamBufferKey(tmdbId: tmdbId, infoHash: hash)))
    }

    public static func loadStreamBufferRanges(
        tmdbId: Int,
        infoHash: String,
        expectedDuration: Double? = nil
    ) -> [ClosedRange<Double>] {
        let hash = infoHash.lowercased()
        guard tmdbId > 0, !hash.isEmpty else { return [] }
        guard let snapshot: StreamBufferSnapshot = readJSON(
            from: streamBufferURL(key: streamBufferKey(tmdbId: tmdbId, infoHash: hash))
        ) else { return [] }
        guard snapshot.tmdbId == tmdbId, snapshot.infoHash == hash else { return [] }
        if let expectedDuration, expectedDuration.isFinite, expectedDuration > 0 {
            let delta = abs(snapshot.durationSeconds - expectedDuration)
            guard delta < max(30, expectedDuration * 0.05) else { return [] }
        }
        return snapshot.timeRanges()
    }

    public static func removeStreamBuffer(tmdbId: Int, infoHash: String) {
        let hash = infoHash.lowercased()
        guard !hash.isEmpty else { return }
        try? FileManager.default.removeItem(
            at: streamBufferURL(key: streamBufferKey(tmdbId: tmdbId, infoHash: hash))
        )
    }

    public struct SweepResult: Sendable {
        public let freedBytes: Int64
        public let removedFiles: Int
    }

    /// TTL + cap for JSON caches under Application Support (not stream `.stream` blobs).
    public static func sweep(
        torrentListMaxAge: TimeInterval = defaultTorrentListTTL,
        streamBufferMaxAge: TimeInterval = 0,
        maxTorrentListFiles: Int = 40
    ) -> SweepResult {
        var freed: Int64 = 0
        var removed = 0
        let now = Date()

        if let torrentDir = try? cacheRoot().appendingPathComponent(torrentListsFolder, isDirectory: true),
           let files = try? FileManager.default.contentsOfDirectory(
               at: torrentDir,
               includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
               options: [.skipsHiddenFiles]
           ) {
            var entries: [(url: URL, date: Date, size: Int64)] = []
            for file in files where file.pathExtension == "json" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if now.timeIntervalSince(modified) > torrentListMaxAge {
                    freed += size
                    try? FileManager.default.removeItem(at: file)
                    removed += 1
                    continue
                }
                entries.append((file, modified, size))
            }
            if entries.count > maxTorrentListFiles {
                let overflow = entries.sorted { $0.date > $1.date }.dropFirst(maxTorrentListFiles)
                for item in overflow {
                    freed += item.size
                    try? FileManager.default.removeItem(at: item.url)
                    removed += 1
                }
            }
        }

        if let bufferDir = try? cacheRoot().appendingPathComponent(streamBuffersFolder, isDirectory: true),
           let files = try? FileManager.default.contentsOfDirectory(
               at: bufferDir,
               includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
               options: [.skipsHiddenFiles]
           ) {
            for file in files where file.pathExtension == "json" {
                if streamBufferMaxAge > 0 {
                    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
                    guard now.timeIntervalSince(modified) > streamBufferMaxAge else { continue }
                }
                let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                freed += size
                try? FileManager.default.removeItem(at: file)
                removed += 1
            }
        }

        return SweepResult(freedBytes: freed, removedFiles: removed)
    }

    // MARK: - Paths

    private static func cacheRoot() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CacheError.supportDirectoryUnavailable
        }
        let root = support
            .appendingPathComponent("MovieBox", isDirectory: true)
            .appendingPathComponent(cacheFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func torrentListURL(for key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return (try? cacheRoot())?
            .appendingPathComponent(torrentListsFolder, isDirectory: true)
            .appendingPathComponent("\(safe).json") ?? URL(fileURLWithPath: "/dev/null")
    }

    private static func streamBufferURL(key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return (try? cacheRoot())?
            .appendingPathComponent(streamBuffersFolder, isDirectory: true)
            .appendingPathComponent("\(safe).json") ?? URL(fileURLWithPath: "/dev/null")
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) {
        guard url.path != "/dev/null" else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("PlaybackDiskCache write failed (\(url.lastPathComponent)): \(error.localizedDescription)")
        }
    }

    private static func readJSON<T: Decodable>(from url: URL) -> T? {
        guard url.path != "/dev/null",
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private enum CacheError: Error {
        case supportDirectoryUnavailable
    }
}
