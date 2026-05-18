import CoreMetadata
import CoreStorage
import CoreTorrent
import Foundation
import MovieBoxCore

public enum MovieDetailTorrentSearch {
    public struct Result: Sendable {
        public let torrents: [TorrentResult]
        public let diagnostics: TorrentSearchDiagnostics?
    }

    @MainActor
    public static func search(
        detail: MovieDetail,
        kind: MediaKind,
        settings: AppSettings?,
        episode: TVEpisode? = nil
    ) async -> Result {
        let backend = settings?.backendTorrentConfig
        let title = detail.movie.title
        let year = Int(detail.movie.releaseDate.prefix(4))
        let imdb = detail.imdbId
        let torrentKind: TorrentioClient.MediaKind = kind == .tv ? .tv : .movie

        let queryOverride: String? = {
            guard kind == .tv, let episode else { return nil }
            return TorrentSearchQuery.makeEpisode(
                showTitle: title,
                season: episode.seasonNumber,
                episode: episode.episodeNumber,
                year: year
            )
        }()

        let aggregator = TorrentSearchAggregator(
            backendBaseURL: backend?.baseURL,
            backendAppToken: backend?.appToken
        )

        let stream = await aggregator.search(
            movieTitle: title,
            year: year,
            imdbId: imdb,
            kind: torrentKind,
            enabledIndexerIDs: settings?.enabledTorrentIndexerSet ?? TorrentIndexerPreferences.defaultIDs,
            queryOverride: queryOverride
        )
        var latest: [TorrentResult] = []
        for await batch in stream {
            latest = batch
        }

        if kind == .tv, let episode {
            latest = TorrentEpisodeFilter.filter(latest, season: episode.seasonNumber, episode: episode.episodeNumber)
        }

        return Result(
            torrents: latest,
            diagnostics: await aggregator.lastDiagnostics
        )
    }

    public static func playFailureMessage(
        diagnostics: TorrentSearchDiagnostics?,
        title: String,
        kind: MediaKind,
        imdbId: String?
    ) -> String {
        let resolved = diagnostics ?? TorrentSearchDiagnostics()
        let missingImdb = imdbId == nil || imdbId?.isEmpty == true
        return resolved.playFailureMessage(title: title, isTV: kind == .tv, missingImdb: missingImdb)
    }
}
