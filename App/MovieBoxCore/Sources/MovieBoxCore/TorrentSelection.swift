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

    /// Continue Watching: same release as last stream when still listed; otherwise top seeded.
    public static func torrentForHeroPlay(
        from torrents: [TorrentResult],
        lastStreamInfoHash: String?,
        hasContinueProgress: Bool
    ) -> TorrentResult? {
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
