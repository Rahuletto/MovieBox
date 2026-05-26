import CoreMetadata
import CoreTorrent
import MovieBoxCore
import SwiftUI

extension MovieDetailView {
    func selectEpisode(_ episode: TVEpisode) async {
        selectedTVEpisode = episode
        if isUpcomingEpisode(episode) {
            torrentPanel.cancelSearch()
            subtitleSearchTask?.cancel()
            torrentPanel.reset()
            subtitles = []
            subtitleFileURL = nil
            selectedSubtitle = nil
            return
        }
        if !restoreTorrentListIfCached(episode: episode) {
            startTorrentSearch(episode: episode)
        }
        if let movie = detail?.movie {
            searchSubtitles(for: movie, episode: episode)
        }
    }

    func latestReleasedEpisode(from episodes: [TVEpisode]) -> TVEpisode? {
        episodes
            .filter { !isUpcomingEpisode($0) }
            .max(by: { $0.episodeNumber < $1.episodeNumber })
    }

    func isUpcomingEpisode(_ episode: TVEpisode) -> Bool {
        guard let date = parseTMDBDate(episode.airDate) else { return false }
        return date > Calendar.current.startOfDay(for: Date())
    }

    func formattedAirDate(_ raw: String?) -> String? {
        guard let date = parseTMDBDate(raw) else { return nil }
        return MovieDetailDateFormatter.display.string(from: date)
    }

    func parseTMDBDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return MovieDetailDateFormatter.parser.date(from: raw)
    }
}

enum MovieDetailDateFormatter {
    static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let display: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
