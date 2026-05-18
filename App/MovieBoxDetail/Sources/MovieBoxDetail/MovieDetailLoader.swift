import CoreMetadata
import CoreStorage
import Foundation
import MovieBoxCore

public enum MovieDetailLoader {
    public struct LoadedState {
        public let detail: MovieDetail
        public let subtitles: [SubtitleInfo]
        public let tvSeasons: [TVSeasonSummary]
        public let tvEpisodes: [TVEpisode]
        public let selectedSeason: Int
        public let selectedEpisode: TVEpisode?
    }

    public enum LoadError: LocalizedError {
        case metadataNotConfigured
        case underlying(Error)

        public var errorDescription: String? {
            switch self {
            case .metadataNotConfigured:
                "Open Settings and configure metadata access first."
            case .underlying(let error):
                error.localizedDescription
            }
        }
    }

    @MainActor
    public static func load(
        movieId: Int,
        kind: MediaKind,
        settings: AppSettings?
    ) async throws -> LoadedState {
        guard let mode = settings?.metadataMode else {
            throw LoadError.metadataNotConfigured
        }

        let client = MetadataClient(mode: mode)
        let loadedDetail = try await client.movieDetail(id: movieId, kind: kind)

        let preferredLang = settings?.preferredSubtitleLang ?? "en"
        let title = loadedDetail.movie.title
        let year = Int(loadedDetail.movie.releaseDate.prefix(4))
        let imdb = loadedDetail.imdbId
        let subtitleClient = SubtitleClient(mode: mode)

        let subtitles: [SubtitleInfo]
        do {
            subtitles = try await subtitleClient.searchSubtitles(
                title: title,
                year: year,
                language: preferredLang,
                imdbId: imdb
            )
        } catch {
            subtitles = []
        }

        if kind == .tv {
            let seasons = try await client.tvSeasonSummaries(showId: movieId)
            let selectedSeason = seasons.last(where: { $0.episodeCount > 0 })?.seasonNumber
                ?? seasons.first?.seasonNumber
                ?? 1
            let episodes = try await client.tvSeasonEpisodes(showId: movieId, season: selectedSeason)
            let selectedEpisode = episodes.first
            return LoadedState(
                detail: loadedDetail,
                subtitles: subtitles,
                tvSeasons: seasons,
                tvEpisodes: episodes,
                selectedSeason: selectedSeason,
                selectedEpisode: selectedEpisode
            )
        }

        return LoadedState(
            detail: loadedDetail,
            subtitles: subtitles,
            tvSeasons: [],
            tvEpisodes: [],
            selectedSeason: 1,
            selectedEpisode: nil
        )
    }

    @MainActor
    public static func loadTVSeasons(
        showId: Int,
        settings: AppSettings?
    ) async throws -> [TVSeasonSummary] {
        guard let mode = settings?.metadataMode else {
            throw LoadError.metadataNotConfigured
        }
        let client = MetadataClient(mode: mode)
        return try await client.tvSeasonSummaries(showId: showId)
    }

    @MainActor
    public static func loadTVEpisodes(
        showId: Int,
        season: Int,
        settings: AppSettings?
    ) async throws -> [TVEpisode] {
        guard let mode = settings?.metadataMode else {
            throw LoadError.metadataNotConfigured
        }
        let client = MetadataClient(mode: mode)
        return try await client.tvSeasonEpisodes(showId: showId, season: season)
    }
}
