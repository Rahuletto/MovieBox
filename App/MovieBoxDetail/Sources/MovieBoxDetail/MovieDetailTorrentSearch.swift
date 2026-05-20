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

    public struct ProgressUpdate: Sendable {
        public let torrents: [TorrentResult]
        public let diagnostics: TorrentSearchDiagnostics?
        public let isComplete: Bool

        public init(torrents: [TorrentResult], diagnostics: TorrentSearchDiagnostics?, isComplete: Bool) {
            self.torrents = torrents
            self.diagnostics = diagnostics
            self.isComplete = isComplete
        }
    }

    @MainActor
    public static func searchStream(
        detail: MovieDetail,
        kind: MediaKind,
        settings: AppSettings?,
        episode: TVEpisode? = nil
    ) -> AsyncStream<ProgressUpdate> {
        AsyncStream { continuation in
            let task = Task {
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

                for await progress in stream {
                    if Task.isCancelled { break }

                    var torrents = progress.torrents
                    if kind == .tv, let episode {
                        torrents = TorrentEpisodeFilter.filter(
                            torrents,
                            season: episode.seasonNumber,
                            episode: episode.episodeNumber
                        )
                    } else if kind == .movie {
                        let runtimeMinutes = detail.movie.runtime ?? detail.enrichment?.runtimeMin
                        torrents = TorrentMovieRelevanceFilter.filter(
                            torrents,
                            movieTitle: title,
                            year: year,
                            runtimeMinutes: runtimeMinutes
                        )
                    }

                    continuation.yield(ProgressUpdate(
                        torrents: torrents,
                        diagnostics: progress.diagnostics,
                        isComplete: progress.isComplete
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    @MainActor
    public static func search(
        detail: MovieDetail,
        kind: MediaKind,
        settings: AppSettings?,
        episode: TVEpisode? = nil
    ) async -> Result {
        var last = Result(torrents: [], diagnostics: nil)
        for await update in searchStream(detail: detail, kind: kind, settings: settings, episode: episode) {
            last = Result(torrents: update.torrents, diagnostics: update.diagnostics ?? last.diagnostics)
        }
        return last
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
