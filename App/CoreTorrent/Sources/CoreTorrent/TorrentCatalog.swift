import Foundation

/// Groups torrent releases for quality / language pickers.
public enum TorrentCatalog {
    public struct Section: Identifiable, Sendable, Hashable {
        public let id: String
        public let quality: VideoQuality
        public let language: String
        public let variants: [TorrentResult]

        public var title: String {
            "\(quality.rawValue) · \(language)"
        }
    }

    public static func sections(from results: [TorrentResult]) -> [Section] {
        let grouped = Dictionary(grouping: results) { torrent in
            "\(torrent.quality.rawValue)|\(torrent.language)"
        }

        return grouped
            .map { key, variants in
                let sorted = variants.sorted { lhs, rhs in
                    if lhs.seeders != rhs.seeders { return lhs.seeders > rhs.seeders }
                    if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
                    return lhs.title < rhs.title
                }
                let sample = sorted[0]
                return Section(
                    id: key,
                    quality: sample.quality,
                    language: sample.language,
                    variants: sorted
                )
            }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                if lhs.language != rhs.language { return lhs.language < rhs.language }
                let lhsSeeders = lhs.variants.first?.seeders ?? 0
                let rhsSeeders = rhs.variants.first?.seeders ?? 0
                return lhsSeeders > rhsSeeders
            }
    }

    /// Best overall pick: highest quality tier, then seeders, then size.
    public static func best(from results: [TorrentResult]) -> TorrentResult? {
        results.max { lhs, rhs in
            if lhs.quality != rhs.quality {
                return lhs.quality < rhs.quality
            }
            if lhs.seeders != rhs.seeders {
                return lhs.seeders < rhs.seeders
            }
            return lhs.sizeBytes < rhs.sizeBytes
        }
    }
}
