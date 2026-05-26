import CoreTorrent
import Foundation

public enum TorrentSelection {
    /// Highest seeder count; quality and size are tiebreakers only.
    public static func topSeeded(from torrents: [TorrentResult]) -> TorrentResult? {
        let seeded = torrents.filter { $0.seeders > 0 }
        let pool = seeded.isEmpty ? torrents : seeded
        return pool.max { lhs, rhs in
            if lhs.seeders != rhs.seeders { return lhs.seeders < rhs.seeders }
            if lhs.quality != rhs.quality { return lhs.quality < rhs.quality }
            return lhs.sizeBytes < rhs.sizeBytes
        }
    }

    /// Hero play: completed download on disk first, then continue-watching hash, then top seeded.
    public static func torrentForHeroPlay(
        from torrents: [TorrentResult],
        lastStreamInfoHash: String?,
        hasContinueProgress: Bool,
        hasCompletedDownload: ((TorrentResult) -> Bool)? = nil
    ) -> TorrentResult? {
        if let hasCompletedDownload {
            let downloaded = torrents.filter(hasCompletedDownload)
            if !downloaded.isEmpty {
                if hasContinueProgress,
                   let hash = lastStreamInfoHash?.lowercased(),
                   !hash.isEmpty,
                   let match = downloaded.first(where: {
                       ($0.resolvedInfoHash ?? "").lowercased() == hash
                   }) {
                    return match
                }
                return downloaded.max { lhs, rhs in
                    if lhs.quality != rhs.quality { return lhs.quality < rhs.quality }
                    return lhs.sizeBytes < rhs.sizeBytes
                }
            }
        }

        if hasContinueProgress,
           let hash = lastStreamInfoHash?.lowercased(),
           !hash.isEmpty,
           let match = torrents.first(where: {
               ($0.resolvedInfoHash ?? "").lowercased() == hash
           }) {
            return match
        }
        return topSeeded(from: torrents)
    }
}
