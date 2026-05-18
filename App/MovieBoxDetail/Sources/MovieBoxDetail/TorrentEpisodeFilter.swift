import CoreTorrent
import Foundation

public enum TorrentEpisodeFilter {
    public static func filter(
        _ results: [TorrentResult],
        season: Int,
        episode: Int
    ) -> [TorrentResult] {
        let episodePatterns = [
            String(format: "S%02dE%02d", season, episode),
            String(format: "S%dE%d", season, episode),
            String(format: "%dx%02d", season, episode),
            String(format: "%dX%02d", season, episode),
        ]

        let seasonPatterns = [
            String(format: "S%02d", season),
            String(format: "S%d", season),
            String(format: "Season %02d", season),
            String(format: "Season %d", season),
        ]

        let filtered = results.filter { torrent in
            let title = torrent.title.uppercased()

            if episodePatterns.contains(where: { title.contains($0.uppercased()) }) {
                return true
            }

            let hasSeason = seasonPatterns.contains(where: { title.contains($0.uppercased()) })
            if hasSeason {
                let isEpisodeTorrent: Bool = {
                    if let regex = try? NSRegularExpression(pattern: #"E(P|ISODE)?\s*\d+"#, options: .caseInsensitive) {
                        let range = NSRange(title.startIndex..., in: title)
                        return regex.firstMatch(in: title, options: [], range: range) != nil
                    }
                    return false
                }()

                let isPack = title.contains("COMPLETE") || title.contains("PACK") || title.contains("SEASON")
                    || title.contains("S\(String(format: "%02d", season)) ")
                    || title.contains("S\(season) ")
                    || !isEpisodeTorrent

                if isPack && !isEpisodeTorrent {
                    return true
                }
            }

            return false
        }
        return filtered.isEmpty ? results : filtered
    }
}
