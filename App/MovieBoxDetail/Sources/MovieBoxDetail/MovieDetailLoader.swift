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

        let subtitles = await loadSubtitles(detail: loadedDetail, settings: settings)

        if kind == .tv {
            let seasons: [TVSeasonSummary]
            if let cachedSeasons = await MovieDetailCache.shared.tvSeasons(showId: movieId) {
                seasons = cachedSeasons
            } else {
                seasons = try await client.tvSeasonSummaries(showId: movieId)
                await MovieDetailCache.shared.insertTVSeasons(seasons, showId: movieId)
            }
            let selectedSeason = seasons.last(where: { $0.episodeCount > 0 })?.seasonNumber
                ?? seasons.first?.seasonNumber
                ?? 1
            
            let episodes: [TVEpisode]
            if let cachedEpisodes = await MovieDetailCache.shared.tvEpisodes(showId: movieId, season: selectedSeason) {
                episodes = cachedEpisodes
            } else {
                episodes = try await client.tvSeasonEpisodes(showId: movieId, season: selectedSeason)
                await MovieDetailCache.shared.insertTVEpisodes(episodes, showId: movieId, season: selectedSeason)
            }
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

    /// Subtitle search can be slow; call from a detached task after the main detail UI is on screen.
    @MainActor
    public static func loadSubtitles(detail: MovieDetail, settings: AppSettings?) async -> [SubtitleInfo] {
        guard let mode = settings?.metadataMode else { return [] }
        let preferredLang = settings?.preferredSubtitleLang ?? "en"
        let title = detail.movie.title
        let year = Int(detail.movie.releaseDate.prefix(4))
        let imdb = detail.imdbId
        let subtitleClient = SubtitleClient(mode: mode)
        do {
            return try await subtitleClient.searchSubtitles(
                title: title,
                year: year,
                language: preferredLang,
                imdbId: imdb
            )
        } catch {
            return []
        }
    }

    @MainActor
    public static func loadTVSeasons(
        showId: Int,
        settings: AppSettings?
    ) async throws -> [TVSeasonSummary] {
        if let cached = await MovieDetailCache.shared.tvSeasons(showId: showId) {
            return cached
        }
        guard let mode = settings?.metadataMode else {
            throw LoadError.metadataNotConfigured
        }
        let client = MetadataClient(mode: mode)
        let seasons = try await client.tvSeasonSummaries(showId: showId)
        await MovieDetailCache.shared.insertTVSeasons(seasons, showId: showId)
        return seasons
    }

    @MainActor
    public static func loadTVEpisodes(
        showId: Int,
        season: Int,
        settings: AppSettings?
    ) async throws -> [TVEpisode] {
        if let cached = await MovieDetailCache.shared.tvEpisodes(showId: showId, season: season) {
            return cached
        }
        guard let mode = settings?.metadataMode else {
            throw LoadError.metadataNotConfigured
        }
        let client = MetadataClient(mode: mode)
        let episodes = try await client.tvSeasonEpisodes(showId: showId, season: season)
        await MovieDetailCache.shared.insertTVEpisodes(episodes, showId: showId, season: season)
        return episodes
    }
}
