import Foundation
import SwiftUI
@preconcurrency import YouTubeKit

/// TMDB-shaped movie metadata. Source: TMDB only.
///
/// Fields sourced from OMDB (IMDb rating, IMDb id, Rotten Tomatoes, Metascore,
/// director, awards, etc.) live exclusively on `MovieDetail.enrichment`
/// (`MovieEnrichment`) and `MovieDetail.imdbId`. They never appear on `Movie`
/// to keep the boundary between TMDB and OMDB explicit.
public struct Movie: Sendable, Codable, Identifiable, Hashable {
    public let id: Int
    public let title: String
    public let overview: String
    public let posterPath: String?
    public let backdropPath: String?
    public let releaseDate: String
    public let voteAverage: Double
    public let genreIds: [Int]
    public var runtime: Int?

    public init(
        id: Int,
        title: String,
        overview: String,
        posterPath: String?,
        backdropPath: String?,
        releaseDate: String,
        voteAverage: Double,
        genreIds: [Int],
        runtime: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.releaseDate = releaseDate
        self.voteAverage = voteAverage
        self.genreIds = genreIds
        self.runtime = runtime
    }
}

public struct Genre: Sendable, Codable, Identifiable, Hashable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

public struct CastMember: Sendable, Codable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let character: String
    public let profilePath: String?

    public init(id: Int, name: String, character: String, profilePath: String?) {
        self.id = id
        self.name = name
        self.character = character
        self.profilePath = profilePath
    }
}

/// Rich metadata sourced from OMDB and merged in server-side. Lives alongside
/// the TMDB-derived fields so we never block on TMDB for ratings / awards /
/// director / etc.
public struct RottenTomatoesStats: Sendable, Codable, Hashable {
    public let percentage: Int           // 91 (percent)
    public let totalReviews: Int?        // total critic reviews
    public let freshCount: Int?          // number of fresh reviews
    public let rottenCount: Int?         // number of rotten reviews
    public let averageScore: Double?     // average score out of 10
    
    public init(
        percentage: Int,
        totalReviews: Int? = nil,
        freshCount: Int? = nil,
        rottenCount: Int? = nil,
        averageScore: Double? = nil
    ) {
        self.percentage = percentage
        self.totalReviews = totalReviews
        self.freshCount = freshCount
        self.rottenCount = rottenCount
        self.averageScore = averageScore
    }
}

public struct MovieEnrichment: Sendable, Codable, Hashable {
    public let imdbRating: Double?       // 7.8
    public let imdbVotes: Int?           // 1_234_567
    public let metascore: Int?           // 74 (out of 100)
    public let rottenTomatoes: Int?      // 91 (percent) — deprecated, use rottenTomatoesStats
    public let rottenTomatoesStats: RottenTomatoesStats?  // detailed RT stats
    public let runtimeMin: Int?
    public let rated: String?            // "PG-13"
    public let released: String?         // "07 Nov 2014"
    public let director: String?
    public let writer: String?
    public let actors: String?           // comma-separated
    public let awards: String?
    public let country: String?
    public let language: String?
    public let boxOffice: String?
    public let production: String?
    public let genre: String?            // comma-separated

    public init(
        imdbRating: Double? = nil,
        imdbVotes: Int? = nil,
        metascore: Int? = nil,
        rottenTomatoes: Int? = nil,
        rottenTomatoesStats: RottenTomatoesStats? = nil,
        runtimeMin: Int? = nil,
        rated: String? = nil,
        released: String? = nil,
        director: String? = nil,
        writer: String? = nil,
        actors: String? = nil,
        awards: String? = nil,
        country: String? = nil,
        language: String? = nil,
        boxOffice: String? = nil,
        production: String? = nil,
        genre: String? = nil
    ) {
        self.imdbRating = imdbRating
        self.imdbVotes = imdbVotes
        self.metascore = metascore
        self.rottenTomatoes = rottenTomatoes
        self.rottenTomatoesStats = rottenTomatoesStats
        self.runtimeMin = runtimeMin
        self.rated = rated
        self.released = released
        self.director = director
        self.writer = writer
        self.actors = actors
        self.awards = awards
        self.country = country
        self.language = language
        self.boxOffice = boxOffice
        self.production = production
        self.genre = genre
    }
}

/// YouTube video from TMDB `videos` (trailers, teasers, clips, etc.).
public struct MediaVideo: Identifiable, Sendable, Hashable, Codable {
    public let key: String
    public let name: String
    public let type: String
    public let official: Bool
    /// YouTube duration in seconds when known (fetched separately).
    public var durationSeconds: Int?

    public var id: String { key }

    public init(
        key: String,
        name: String,
        type: String,
        official: Bool = false,
        durationSeconds: Int? = nil
    ) {
        self.key = key
        self.name = name
        self.type = type
        self.official = official
        self.durationSeconds = durationSeconds
    }

    public var youtubeWatchURL: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(key)")
    }

    /// YouTube still image for the clip card. Uses **sddefault** (640×480) so previews never match the old tiny `mqdefault` (~320×180) tiles.
    public var thumbnailURL: URL? {
        URL(string: "https://img.youtube.com/vi/\(key)/sddefault.jpg")
    }

    public var normalizedType: String { type.lowercased() }

    public var isTrailerCategory: Bool {
        normalizedType == "trailer" || normalizedType == "teaser"
    }

    public var isClipCategory: Bool {
        !isTrailerCategory
    }

    public var displayType: String {
        type.isEmpty ? "Video" : type.capitalized
    }

    public var formattedDuration: String? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Typical trailer: ~1–4 minutes; teasers shorter. Unknown duration is allowed.
    public func matchesExpectedDuration(forTrailerTab: Bool, resolvedDuration: Int? = nil) -> Bool {
        guard let duration = resolvedDuration ?? durationSeconds else { return true }
        guard forTrailerTab else { return true }
        switch normalizedType {
        case "trailer":
            return (40...360).contains(duration)
        case "teaser":
            return (8...150).contains(duration)
        default:
            return duration <= 420
        }
    }

    public func sortScore(durationSeconds resolvedDuration: Int?) -> Int {
        let duration = resolvedDuration ?? durationSeconds
        var score = 0
        if official { score += 200 }
        switch normalizedType {
        case "trailer": score += 120
        case "teaser": score += 60
        default: break
        }
        let lower = name.lowercased()
        if lower.contains("official trailer") { score += 80 }
        if lower.contains("main trailer") { score += 40 }
        if lower.contains("final trailer") { score += 30 }
        if let duration {
            switch normalizedType {
            case "trailer":
                score += max(0, 50 - abs(duration - 120) / 4)
                if duration > 600 { score -= 120 }
            case "teaser":
                score += max(0, 30 - abs(duration - 45) / 3)
                if duration > 180 { score -= 60 }
            default:
                break
            }
        }
        return score
    }

    public static func sortedTrailers(
        _ videos: [MediaVideo],
        durations: [String: Int] = [:]
    ) -> [MediaVideo] {
        videos
            .filter(\.isTrailerCategory)
            .filter { $0.matchesExpectedDuration(forTrailerTab: true, resolvedDuration: durations[$0.key]) }
            .sorted {
                $0.sortScore(durationSeconds: durations[$0.key]) >
                    $1.sortScore(durationSeconds: durations[$1.key])
            }
    }

    public static func sortedClips(
        _ videos: [MediaVideo],
        durations: [String: Int] = [:]
    ) -> [MediaVideo] {
        videos
            .filter(\.isClipCategory)
            .sorted {
                $0.sortScore(durationSeconds: durations[$0.key]) >
                    $1.sortScore(durationSeconds: durations[$1.key])
            }
    }

}

public struct MovieDetail: Sendable, Codable, Identifiable, Hashable {
    public var id: Int { movie.id }
    public let movie: Movie
    public let genres: [Genre]
    public let cast: [CastMember]
    public let trailerURL: URL?
    /// Direct HLS URL from Rotten Tomatoes / Fandango MPX (backend-resolved). Used when YouTube → Piped resolution fails or when there is no TMDB trailer.
    public let trailerRTStreamURL: URL?
    /// All YouTube videos from TMDB (trailers, clips, featurettes, …).
    public let videos: [MediaVideo]
    public let similar: [Movie]
    /// Pre-resolved fanart logo (returned by the backend bundle endpoint).
    /// When non-nil, `AsyncLogoView` will skip its own network fetch.
    public let logoURL: URL?
    /// IMDb id pulled from TMDB external_ids — useful for subtitle / OMDb lookups
    /// without doing another /external_ids call.
    public let imdbId: String?
    /// OMDB-sourced enrichment (IMDB rating, RT, Metascore, director, awards…).
    public let enrichment: MovieEnrichment?
    /// TMDB regional descriptors (e.g. "Contains Violence") when available.
    public let contentWarnings: [String]

    public init(
        movie: Movie,
        genres: [Genre],
        cast: [CastMember] = [],
        trailerURL: URL? = nil,
        trailerRTStreamURL: URL? = nil,
        videos: [MediaVideo] = [],
        similar: [Movie] = [],
        logoURL: URL? = nil,
        imdbId: String? = nil,
        enrichment: MovieEnrichment? = nil,
        contentWarnings: [String] = []
    ) {
        self.movie = movie
        self.genres = genres
        self.cast = cast
        self.trailerURL = trailerURL
        self.trailerRTStreamURL = trailerRTStreamURL
        self.videos = videos
        self.similar = similar
        self.logoURL = logoURL
        self.imdbId = imdbId
        self.enrichment = enrichment
        self.contentWarnings = contentWarnings
    }
}

public struct TVSeasonSummary: Sendable, Identifiable, Hashable, Codable {
    public let seasonNumber: Int
    public let name: String
    public let episodeCount: Int
    public let posterPath: String?

    public var id: Int { seasonNumber }

    public init(seasonNumber: Int, name: String, episodeCount: Int, posterPath: String?) {
        self.seasonNumber = seasonNumber
        self.name = name
        self.episodeCount = episodeCount
        self.posterPath = posterPath
    }
}

public struct TVEpisode: Sendable, Identifiable, Hashable, Codable {
    public let id: Int
    public let seasonNumber: Int
    public let episodeNumber: Int
    public let name: String
    public let overview: String
    public let airDate: String?
    public let stillPath: String?
    public let runtime: Int?

    public init(
        id: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        name: String,
        overview: String,
        airDate: String?,
        stillPath: String?,
        runtime: Int?
    ) {
        self.id = id
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.name = name
        self.overview = overview
        self.airDate = airDate
        self.stillPath = stillPath
        self.runtime = runtime
    }
}

public enum MetadataEndpointMode: Sendable, Equatable {
    case direct(tmdbBearerToken: String, omdbAPIKey: String?)
    case backend(baseURL: URL, appToken: String)
}

public enum MediaKind: String, Sendable, Hashable, Codable {
    case movie
    case tv
}

public enum MetadataCategory: String, Sendable, CaseIterable, Identifiable {
    case trending = "Trending This Week"
    case popular = "Popular Right Now"
    case topRated = "Top Rated"
    case nowPlaying = "Now In Theatres"

    public var id: String { rawValue }

    public func displayTitle(for kind: MediaKind) -> String {
        switch (self, kind) {
        case (.nowPlaying, .tv): "Airing Today"
        case (.popular, .tv): "Popular Shows"
        case (.topRated, .tv): "Top Rated Shows"
        case (.trending, .tv): "Trending Shows"
        default: rawValue
        }
    }

    func tmdbPath(kind: MediaKind = .movie) -> String {
        switch (self, kind) {
        case (.trending, .movie): "/trending/movie/week"
        case (.trending, .tv): "/trending/tv/week"
        case (.popular, .movie): "/movie/popular"
        case (.popular, .tv): "/tv/popular"
        case (.topRated, .movie): "/movie/top_rated"
        case (.topRated, .tv): "/tv/top_rated"
        case (.nowPlaying, .movie): "/movie/now_playing"
        case (.nowPlaying, .tv): "/tv/airing_today"
        }
    }
}

public enum MetadataError: Error, Sendable, LocalizedError {
    case missingConfiguration
    case invalidURL
    case upstream(Int)
    case trailerUnavailable

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration: "Missing metadata API configuration."
        case .invalidURL: "Could not build metadata request URL."
        case .upstream(let status): "Metadata service returned HTTP \(status)."
        case .trailerUnavailable:
            "No playable trailer stream was found. Try another clip or check your connection."
        }
    }
}

public actor MetadataClient {
    private let mode: MetadataEndpointMode?
    private let session: URLSession
    private let decoder: JSONDecoder
    private let tmdbToken: String?
    private var lastNetworkProbeMbps: Double?
    private var lastNetworkProbeAt: Date?

    public init(mode: MetadataEndpointMode? = nil, session: URLSession? = nil, tmdbToken: String? = nil) {
        self.mode = mode
        self.tmdbToken = tmdbToken
        if let session {
            self.session = session
        } else if case .backend = mode {
            self.session = BackendURLSession.urlSession
        } else {
            self.session = .shared
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    public func movies(for category: MetadataCategory, kind: MediaKind = .movie, page: Int = 1) async throws -> [Movie] {
        let response: MovieListResponse = try await request(path: category.tmdbPath(kind: kind), queryItems: [URLQueryItem(name: "page", value: String(page))])
        return await MovieRegistry.shared.canonicalize(response.results.map(\.movie), kind: kind)
    }

    public func searchMovies(query: String, kind: MediaKind = .movie, page: Int = 1) async throws -> [Movie] {
        let endpoint = kind == .movie ? "/search/movie" : "/search/tv"
        let response: MovieListResponse = try await request(
            path: endpoint,
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "page", value: String(page))
            ]
        )
        return await MovieRegistry.shared.canonicalize(response.results.map(\.movie), kind: kind)
    }

    public func discoverMovies(genreId: Int, kind: MediaKind = .movie, page: Int = 1) async throws -> [Movie] {
        let endpoint = kind == .movie ? "/discover/movie" : "/discover/tv"
        let response: MovieListResponse = try await request(
            path: endpoint,
            queryItems: [
                URLQueryItem(name: "with_genres", value: String(genreId)),
                URLQueryItem(name: "sort_by", value: "popularity.desc"),
                URLQueryItem(name: "page", value: String(page))
            ]
        )
        return await MovieRegistry.shared.canonicalize(response.results.map(\.movie), kind: kind)
    }

    public func discoverCurated(kind: MediaKind = .movie, queryItems: [URLQueryItem], page: Int = 1) async throws -> [Movie] {
        let endpoint = kind == .movie ? "/discover/movie" : "/discover/tv"
        var allItems = queryItems
        allItems.append(URLQueryItem(name: "page", value: String(page)))
        let response: MovieListResponse = try await request(path: endpoint, queryItems: allItems)
        return await MovieRegistry.shared.canonicalize(response.results.map(\.movie), kind: kind)
    }

    public func keywordID(matching query: String) async throws -> Int? {
        let response: KeywordSearchResponse = try await request(
            path: "/search/keyword",
            queryItems: [URLQueryItem(name: "query", value: query)]
        )
        return response.results.first?.id
    }

    public func discoverByKeyword(kind: MediaKind = .movie, keywordID: Int, page: Int = 1) async throws -> [Movie] {
        try await discoverCurated(
            kind: kind,
            queryItems: [URLQueryItem(name: "with_keywords", value: String(keywordID))],
            page: page
        )
    }

    public func movieSummary(id: Int, kind: MediaKind = .movie) async throws -> Movie {
        let base = kind == .movie ? "/movie" : "/tv"
        let dto: TMDBMovieDTO = try await request(path: "\(base)/\(id)")
        return await MovieRegistry.shared.canonicalize(dto.movie, kind: kind)
    }

    public func personDetail(id: Int) async throws -> PersonDetail {
        guard let mode else { throw MetadataError.missingConfiguration }

        if case .backend(let baseURL, let appToken) = mode {
            let url = baseURL.appending(path: "api/person/\(id)")
            var request = URLRequest(url: url)
            request.setValue(appToken, forHTTPHeaderField: "X-MovieBox-Token")
            request.timeoutInterval = 20
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw MetadataError.upstream(http.statusCode)
            }
            let bundle = try decoder.decode(TMDBPersonBundleDTO.self, from: data)
            return PersonDetailMapper.map(bundle: bundle)
        }

        let bundle: TMDBPersonBundleDTO = try await request(
            path: "/person/\(id)",
            queryItems: [URLQueryItem(name: "append_to_response", value: "combined_credits,external_ids")]
        )
        return PersonDetailMapper.map(bundle: bundle)
    }

    public func movieDetail(id: Int, kind: MediaKind = .movie) async throws -> MovieDetail {
        if let cached = await MovieDetailCache.shared.detail(id: id, kind: kind) {
            return cached
        }
        guard let mode else { throw MetadataError.missingConfiguration }

        let detail: MovieDetail
        // Backend mode: use the bundle endpoint (1 RTT, server resolves credits +
        // similar + external_ids + videos + fanart logo from KV).
        if case .backend(let baseURL, let appToken) = mode {
            let url = baseURL.appending(path: "api/title/\(kind.rawValue)/\(id)")
            var request = URLRequest(url: url)
            request.setValue(appToken, forHTTPHeaderField: "X-MovieBox-Token")
            request.timeoutInterval = 20
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw MetadataError.upstream(http.statusCode)
            }
            let bundle = try decoder.decode(TitleBundleDTO.self, from: data)
            let rawDetail = bundle.detail(kind: kind)

            // Pre-seed LogoCache so AsyncLogoView in the detail header skips its fetch.
            if let logoURL = rawDetail.logoURL {
                await LogoCache.shared.seed(kind: kind, id: id, url: logoURL)
            } else {
                // Negative result is also worth seeding so we don't re-resolve.
                await LogoCache.shared.seed(kind: kind, id: id, url: nil)
            }
            
            let canonicalMovie = await MovieRegistry.shared.canonicalize(rawDetail.movie, kind: kind)
            let canonicalSimilar = await MovieRegistry.shared.canonicalize(rawDetail.similar, kind: kind)
            detail = MovieDetail(
                movie: canonicalMovie,
                genres: rawDetail.genres,
                cast: rawDetail.cast,
                trailerURL: rawDetail.trailerURL,
                trailerRTStreamURL: rawDetail.trailerRTStreamURL,
                videos: rawDetail.videos,
                similar: canonicalSimilar,
                logoURL: rawDetail.logoURL,
                imdbId: rawDetail.imdbId,
                enrichment: rawDetail.enrichment,
                contentWarnings: rawDetail.contentWarnings
            )
        } else {
            // Direct mode (no backend): fall back to individual TMDB calls.
            let base = kind == .movie ? "/movie" : "/tv"
            async let movieResponse: TMDBMovieDTO = request(path: "\(base)/\(id)")
            async let creditsResponse: CreditsResponse = request(path: "\(base)/\(id)/credits")
            async let similarResponse: MovieListResponse = request(path: "\(base)/\(id)/similar")

            let contentWarnings: [String]
            switch kind {
            case .movie:
                let releaseDates: TMDBReleaseDatesAppendDTO = try await request(path: "\(base)/\(id)/release_dates")
                contentWarnings = ContentAdvisoryExtractor.fromMovieReleaseDates(releaseDates.results)
            case .tv:
                let ratings: TMDBContentRatingsAppendDTO = try await request(path: "\(base)/\(id)/content_ratings")
                contentWarnings = ContentAdvisoryExtractor.fromTVContentRatings(ratings.results)
            }

            let movie = try await movieResponse.movie
            let credits = try await creditsResponse.cast.prefix(16).map(\.castMember)
            let similar = try await similarResponse.results.map(\.movie)
            
            let canonicalMovie = await MovieRegistry.shared.canonicalize(movie, kind: kind)
            let canonicalSimilar = await MovieRegistry.shared.canonicalize(similar, kind: kind)
            
            detail = MovieDetail(
                movie: canonicalMovie,
                genres: try await movieResponse.genres ?? [],
                cast: Array(credits),
                similar: canonicalSimilar,
                contentWarnings: contentWarnings
            )
        }

        await MovieDetailCache.shared.insertDetail(detail, id: id, kind: kind)
        return detail
    }

    /// Season list for a TV show (excludes specials / season 0).
    public func tvSeasonSummaries(showId: Int) async throws -> [TVSeasonSummary] {
        let response: TVShowSeasonsDTO = try await request(path: "/tv/\(showId)")
        return (response.seasons ?? [])
            .filter { $0.seasonNumber > 0 }
            .sorted { $0.seasonNumber < $1.seasonNumber }
            .map {
                TVSeasonSummary(
                    seasonNumber: $0.seasonNumber,
                    name: $0.name ?? "Season \($0.seasonNumber)",
                    episodeCount: $0.episodeCount ?? 0,
                    posterPath: $0.posterPath
                )
            }
    }

    public func tvSeasonEpisodes(showId: Int, season: Int) async throws -> [TVEpisode] {
        let response: TVSeasonDetailDTO = try await request(path: "/tv/\(showId)/season/\(season)")
        return (response.episodes ?? [])
            .sorted { $0.episodeNumber < $1.episodeNumber }
            .map {
                TVEpisode(
                    id: $0.id,
                    seasonNumber: season,
                    episodeNumber: $0.episodeNumber,
                    name: $0.name ?? "Episode \($0.episodeNumber)",
                    overview: $0.overview ?? "",
                    airDate: $0.airDate,
                    stillPath: $0.stillPath,
                    runtime: $0.runtime
                )
            }
    }

    public func resolveTrailer(key: String) async throws -> URL {
        guard mode != nil else { throw MetadataError.missingConfiguration }

        await TrailerStreamRelay.shared.stop()

        // Native, on-device extraction of playable streams from YouTube.
        // Choose quality based on current throughput with an "edge-up" rule.
        // Sub-480p muxed streams are only used when nothing ≥480p is available.
        let streams = try await YouTube(videoID: key).streams
        let playableMuxed = Array(streams
            .filterVideoAndAudio()
            .filter { $0.isNativelyPlayable })

        if playableMuxed.isEmpty {
            throw MetadataError.trailerUnavailable
        }

        let candidates = playableMuxed.map { stream in
            TrailerStreamCandidate(
                url: stream.url,
                tier: inferredTier(from: stream.url),
                score: streamScore(stream.url)
            )
        }
        /// Never prefer sub-480p muxed streams when any ≥480p option exists (YouTube still serves itag 18 on some titles).
        let tierPool = candidatesAtLeastMinimumDisplayTier(candidates)
        let throughputMbps = await measuredNetworkMbps(probeURL: tierPool.max(by: { $0.score < $1.score })?.url)

        if let throughputMbps {
            let suggested = tierForThroughput(mbps: throughputMbps)
            let target = edgeUpTier(from: suggested)
            if let adaptivePick = pickBestCandidate(tierPool, targetTier: target) {
                return adaptivePick.url
            }
        }

        if let scoredBest = tierPool.max(by: { $0.score < $1.score }) {
            return scoredBest.url
        }

        throw MetadataError.trailerUnavailable
    }

    private struct TrailerStreamCandidate: Sendable {
        let url: URL
        let tier: Int
        let score: Int
    }

    private func candidatesAtLeastMinimumDisplayTier(_ candidates: [TrailerStreamCandidate]) -> [TrailerStreamCandidate] {
        let minimumTier = 480
        let filtered = candidates.filter { $0.tier >= minimumTier }
        return filtered.isEmpty ? candidates : filtered
    }

    private func tierForThroughput(mbps: Double) -> Int {
        switch mbps {
        case ..<0.9: 480
        case ..<1.8: 480
        case ..<3.8: 720
        case ..<8.0: 1080
        case ..<14.0: 1440
        default: 2160
        }
    }

    private func edgeUpTier(from suggested: Int) -> Int {
        let tier: Int
        switch suggested {
        case ..<480: tier = 480
        case ..<720: tier = 720
        case ..<1080: tier = 1080
        case ..<1440: tier = 1440
        default: tier = 2160
        }
        return max(480, tier)
    }

    private func pickBestCandidate(_ candidates: [TrailerStreamCandidate], targetTier: Int) -> TrailerStreamCandidate? {
        let suitable = candidates.filter { $0.tier >= targetTier }
        if let bestSuitable = suitable.max(by: { $0.score < $1.score }) {
            return bestSuitable
        }
        return candidates.max(by: { $0.score < $1.score })
    }

    private func inferredTier(from url: URL) -> Int {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let itag = Int(query["itag"] ?? "")
        if let itag {
            switch itag {
            case 38: return 2160
            case 37: return 1080
            case 22: return 720
            case 59, 78: return 480
            case 18: return 360
            default: break
            }
        }

        let quality = (query["quality"] ?? "").lowercased()
        if quality.contains("hd2160") { return 2160 }
        if quality.contains("hd1440") { return 1440 }
        if quality.contains("hd1080") { return 1080 }
        if quality.contains("hd720") { return 720 }
        if quality.contains("large") { return 480 }
        if quality.contains("medium") { return 480 }
        return 480
    }

    private func streamScore(_ url: URL) -> Int {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let itag = Int(query["itag"] ?? "")

        // Prefer known high-quality muxed itags first.
        let itagScore: Int = switch itag {
        case 38: 4000 // 3072p
        case 37: 3000 // 1080p
        case 22: 2000 // 720p
        case 59, 78: 1500 // 480p
        case 18: 1000 // 360p
        default: 0
        }

        let quality = (query["quality"] ?? "").lowercased()
        let qualityScore: Int
        if quality.contains("hd2160") { qualityScore = 3500 }
        else if quality.contains("hd1440") { qualityScore = 3200 }
        else if quality.contains("hd1080") { qualityScore = 3000 }
        else if quality.contains("hd720") { qualityScore = 2000 }
        else if quality.contains("large") { qualityScore = 1500 }
        else if quality.contains("medium") { qualityScore = 1000 }
        else { qualityScore = 0 }

        // Slightly prefer streams with larger explicit bitrate values.
        let bitrateScore = Int(query["bitrate"] ?? "") ?? 0

        return max(itagScore, qualityScore) * 10_000 + bitrateScore
    }

    private func measuredNetworkMbps(probeURL: URL?) async -> Double? {
        if let cached = lastNetworkProbeMbps,
           let at = lastNetworkProbeAt,
           Date().timeIntervalSince(at) < 45 {
            return cached
        }
        guard let probeURL else { return nil }

        var request = URLRequest(url: probeURL)
        request.setValue("bytes=0-524287", forHTTPHeaderField: "Range")
        request.timeoutInterval = 4

        let start = Date()
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let elapsed = max(Date().timeIntervalSince(start), 0.2)
            let bits = Double(data.count * 8)
            let mbps = bits / elapsed / 1_000_000
            lastNetworkProbeMbps = mbps
            lastNetworkProbeAt = Date()
            return mbps
        } catch {
            return lastNetworkProbeMbps
        }
    }

    /// Returns an absolute Fanart.tv logo URL (NOT a TMDB path).
    /// Single backend RTT — server-side resolves external_ids → fanart and caches
    /// every step (including negatives) in KV. Frontend additionally caches in
    /// process memory via `LogoCache` to deduplicate concurrent lookups.
    public func movieLogoURL(id: Int, kind: MediaKind = .movie) async throws -> URL? {
        let cache = LogoCache.shared
        if let cached = await cache.lookup(kind: kind, id: id) {
            return cached.url
        }

        return try await cache.resolve(kind: kind, id: id) { [self] in
            do {
                let response: LogoResponse = try await logoRequest(kind: kind, id: id)
                guard let raw = response.url else { return nil }
                return URL(string: raw)
            } catch {
                return nil
            }
        }
    }

    /// Deprecated: previous API returned a String that callers mistakenly fed back
    /// into `imageURL(path:)`, producing broken `https://image.tmdb.org/t/p/w1000https://...`
    /// URLs. Use `movieLogoURL(id:kind:)` instead.
    @available(*, deprecated, renamed: "movieLogoURL(id:kind:)")
    public func movieLogoPath(id: Int, kind: MediaKind = .movie) async throws -> String? {
        return try await movieLogoURL(id: id, kind: kind)?.absoluteString
    }

    private func logoRequest(kind: MediaKind, id: Int) async throws -> LogoResponse {
        guard let mode else { throw MetadataError.missingConfiguration }
        switch mode {
        case .backend(let baseURL, let appToken):
            let url = baseURL.appending(path: "api/logo/\(kind.rawValue)/\(id)")
            var request = URLRequest(url: url)
            request.setValue(appToken, forHTTPHeaderField: "X-MovieBox-Token")
            request.timeoutInterval = 20
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw MetadataError.upstream(http.statusCode)
            }
            return try decoder.decode(LogoResponse.self, from: data)
        case .direct:
            // Direct mode has no backend; cannot resolve logos without it.
            return LogoResponse(url: nil)
        }
    }

    public func movieImages(id: Int, kind: MediaKind = .movie) async throws -> (logo: URL?, backdrop: String?) {
        let base = kind == .movie ? "/movie" : "/tv"

        // Get logo from Fanart (absolute URL)
        let logoURL = try await movieLogoURL(id: id, kind: kind)

        // Get backdrop from TMDB (relative path — combine with `imageURL(path:)` to render)
        let response: ImagesResponse = try await request(
            path: "\(base)/\(id)/images"
        )

        return (
            logo: logoURL,
            backdrop: (response.backdrops ?? []).first?.filePath
        )
    }

    public nonisolated func imageURL(path: String?, width: Int = 342) -> URL? {
        guard let path else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w\(width)\(path)")
    }

    /// Poster-shaped UI: prefer poster art, fall back to backdrop when poster is missing (common for some TV / catalog entries).
    public nonisolated func posterDisplayURL(posterPath: String?, backdropPath: String?, width: Int = 342) -> URL? {
        imageURL(path: posterPath, width: width) ?? imageURL(path: backdropPath, width: width)
    }

    private func request<T: Decodable & Sendable>(path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        guard let mode else { throw MetadataError.missingConfiguration }
        var request = try makeRequest(path: path, queryItems: queryItems, mode: mode)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MetadataError.upstream(http.statusCode)
        }
        return try decoder.decode(T.self, from: data)
    }
    
    private func requestDirect<T: Decodable & Sendable>(path: String, queryItems: [URLQueryItem] = [], token: String) async throws -> T {
        var components = URLComponents(string: "https://api.themoviedb.org/3\(path)")
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else { throw MetadataError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MetadataError.upstream(http.statusCode)
        }
        return try decoder.decode(T.self, from: data)
    }

    private func makeRequest(path: String, queryItems: [URLQueryItem], mode: MetadataEndpointMode) throws -> URLRequest {
        switch mode {
        case .direct(let token, _):
            var components = URLComponents(string: "https://api.themoviedb.org/3\(path)")
            components?.queryItems = queryItems.isEmpty ? nil : queryItems
            guard let url = components?.url else { throw MetadataError.invalidURL }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        case .backend(let baseURL, let appToken):
            var components = URLComponents(url: baseURL.appending(path: "api/tmdb\(path)"), resolvingAgainstBaseURL: false)
            components?.queryItems = queryItems.isEmpty ? nil : queryItems
            guard let url = components?.url else { throw MetadataError.invalidURL }
            var request = URLRequest(url: url)
            request.setValue(appToken, forHTTPHeaderField: "X-MovieBox-Token")
            return request
        }
    }
}

public actor ImageLoader {
    private let session: URLSession
    private var inFlight: [URL: Task<Data, Error>] = [:]
    private static nonisolated(unsafe) var sharedLoader: ImageLoader?

    public static func shared() -> ImageLoader {
        if let existing = sharedLoader {
            return existing
        }
        let new = ImageLoader()
        sharedLoader = new
        return new
    }

    public init(memoryCapacity: Int = 50 * 1024 * 1024, diskCapacity: Int = 250 * 1024 * 1024) {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        self.session = URLSession(configuration: configuration)
    }

    public func data(for url: URL) async throws -> Data {
        if let task = inFlight[url] {
            return try await task.value
        }
        let task = Task<Data, Error> {
            let (data, _) = try await session.data(from: url)
            return data
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        return try await task.value
    }
}

private struct MovieListResponse: Decodable, Sendable {
    let results: [TMDBMovieDTO]
}

private struct KeywordSearchResponse: Decodable, Sendable {
    struct KeywordDTO: Decodable, Sendable {
        let id: Int
        let name: String
    }

    let results: [KeywordDTO]
}

private struct CreditsResponse: Decodable, Sendable {
    let cast: [TMDBCastDTO]
}

private struct ImagesResponse: Decodable, Sendable {
    let posters: [TMDBImageDTO]?
    let backdrops: [TMDBImageDTO]?
}

private struct LogoResponse: Decodable, Sendable {
    let url: String?
}

/// Process-wide cache + request coalescer for resolved logo URLs.
///
/// - Positive cache entries live for 24h (the backend's URL is stable).
/// - Negative entries (movies/TV with no logo on fanart) live for 1h to avoid
///   re-hammering the backend during scrolls/re-renders.
/// - Concurrent requests for the same `(kind, id)` are coalesced onto a single
///   in-flight Task so we never do duplicate network work.
public actor LogoCache {
    public struct Entry: Sendable {
        public let url: URL?
        public let expires: Date
    }

    public static let shared = LogoCache()

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<URL?, Error>] = [:]

    private static let positiveTTL: TimeInterval = 60 * 60 * 24  // 24h
    private static let negativeTTL: TimeInterval = 60 * 60       // 1h

    private func key(_ kind: MediaKind, _ id: Int) -> String { "\(kind.rawValue):\(id)" }

    /// Returns a cached entry if still valid, otherwise nil.
    public func lookup(kind: MediaKind, id: Int) -> Entry? {
        let k = key(kind, id)
        guard let entry = entries[k] else { return nil }
        if entry.expires < Date() {
            entries.removeValue(forKey: k)
            return nil
        }
        return entry
    }

    /// Resolves the logo URL, deduplicating concurrent calls.
    /// `loader` is invoked at most once per (kind, id) per refresh cycle.
    public func resolve(
        kind: MediaKind,
        id: Int,
        loader: @Sendable @escaping () async -> URL?
    ) async throws -> URL? {
        let k = key(kind, id)
        if let entry = lookup(kind: kind, id: id) { return entry.url }
        if let inflight = inFlight[k] { return try await inflight.value }

        let task = Task<URL?, Error> {
            await loader()
        }
        inFlight[k] = task
        defer { inFlight.removeValue(forKey: k) }

        let resolved = try await task.value
        let ttl = resolved == nil ? Self.negativeTTL : Self.positiveTTL
        entries[k] = Entry(url: resolved, expires: Date().addingTimeInterval(ttl))
        return resolved
    }

    public func clear() {
        entries.removeAll()
    }

    /// Seed an entry from a known source (e.g., the backend bundle endpoint)
    /// so subsequent lookups are immediate.
    public func seed(kind: MediaKind, id: Int, url: URL?) {
        let ttl = url == nil ? Self.negativeTTL : Self.positiveTTL
        entries[key(kind, id)] = Entry(url: url, expires: Date().addingTimeInterval(ttl))
    }
}

/// Prefetches detail bundles in the background to warm the backend KV cache.
/// Triggered on hover (and could also be used for carousel-next-slide warming).
/// Idempotent — never re-prefetches an id already fetched or in-flight.
public actor Prefetcher {
    public static let shared = Prefetcher()

    private var done: Set<String> = []
    private var inflight: Set<String> = []
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 6
        // Discard the response body — we only care about warming the backend cache.
        self.session = URLSession(configuration: config)
    }

    /// Fire-and-forget — warms `/api/title/:kind/:id` for the given movie.
    /// Safe to call repeatedly; deduplicates internally.
    public func prefetchDetail(id: Int, kind: MediaKind, mode: MetadataEndpointMode) {
        guard case .backend(let baseURL, let appToken) = mode else { return }
        let key = "\(kind.rawValue):\(id)"
        if done.contains(key) || inflight.contains(key) { return }
        inflight.insert(key)

        let url = baseURL.appending(path: "api/title/\(kind.rawValue)/\(id)")
        var request = URLRequest(url: url)
        request.setValue(appToken, forHTTPHeaderField: "X-MovieBox-Token")
        request.timeoutInterval = 15

        Task.detached { [session] in
            // We intentionally swallow errors — prefetch is best-effort.
            _ = try? await session.data(for: request)
            await Prefetcher.shared.complete(key: key)
        }
    }

    /// Pre-warms an image URL through the on-disk URLCache so a subsequent
    /// `CachedImageView` / `AsyncImage` returns instantly.
    public func prefetchImage(url: URL?) {
        guard let url else { return }
        let key = "img:\(url.absoluteString)"
        if done.contains(key) || inflight.contains(key) { return }
        inflight.insert(key)

        Task.detached { [session] in
            _ = try? await session.data(from: url)
            await Prefetcher.shared.complete(key: key)
        }
    }

    private func complete(key: String) {
        inflight.remove(key)
        done.insert(key)
    }

    /// Clear the dedupe set — call when user signs out / changes endpoints.
    public func reset() {
        done.removeAll()
        inflight.removeAll()
    }
}

// MARK: - Backend bundle decoding

private struct TitleBundleDTO: Decodable, Sendable {
    let id: Int
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let genreIds: [Int]?
    let runtime: Int?
    let episodeRunTime: [Int]?
    let genres: [Genre]?
    let credits: CreditsBundleDTO?
    let similar: SimilarBundleDTO?
    let externalIds: ExternalIdsDTO?
    let videos: VideosBundleDTO?
    let movieboxLogo: String?
    /// HLS playlist URL when RT hosts the trailer (MPX / Akamai); direct AVPlayer playback.
    let movieboxTrailerRtHls: String?
    /// OMDB-sourced enrichment payload (ratings, director, awards, etc.).
    /// This is the *only* place OMDB-derived data enters the type system.
    let movieboxEnrichment: EnrichmentDTO?
    let releaseDates: TMDBReleaseDatesAppendDTO?
    let contentRatings: TMDBContentRatingsAppendDTO?

    func detail(kind: MediaKind) -> MovieDetail {
        let resolvedTitle = title ?? name ?? "Untitled"
        let resolvedDate = releaseDate ?? firstAirDate ?? ""
        // Runtime: prefer TMDB's; for TV, fall back to first episode runtime;
        // last resort OMDB's reported runtime. Pure TMDB-vs-OMDB precedence.
        let resolvedRuntime = runtime ?? episodeRunTime?.first ?? movieboxEnrichment?.runtimeMin
        // IMDb id is always read from `external_ids.imdb_id` — the backend has
        // already merged any OMDB-recovered id into that field, so this stays
        // a single source of truth on the wire.
        let resolvedImdbId = externalIds?.imdbId

        let movie = Movie(
            id: id,
            title: resolvedTitle,
            overview: overview ?? "",
            posterPath: posterPath,
            backdropPath: backdropPath,
            releaseDate: resolvedDate,
            voteAverage: voteAverage ?? 0,
            genreIds: genreIds ?? genres?.map(\.id) ?? [],
            runtime: resolvedRuntime
        )

        let cast = (credits?.cast ?? []).prefix(16).map(\.castMember)
        let similarMovies = (similar?.results ?? []).map(\.movie)
        let trailer = videos?.preferredTrailerURL
        let mediaVideos = videos?.youtubeVideos ?? []
        let contentWarnings: [String] = switch kind {
        case .movie:
            ContentAdvisoryExtractor.fromMovieReleaseDates(releaseDates?.results)
        case .tv:
            ContentAdvisoryExtractor.fromTVContentRatings(contentRatings?.results)
        }

        return MovieDetail(
            movie: movie,
            genres: genres ?? [],
            cast: Array(cast),
            trailerURL: trailer,
            trailerRTStreamURL: movieboxTrailerRtHls.flatMap(URL.init(string:)),
            videos: mediaVideos,
            similar: similarMovies,
            logoURL: movieboxLogo.flatMap(URL.init(string:)),
            imdbId: resolvedImdbId,
            enrichment: movieboxEnrichment?.toEnrichment(),
            contentWarnings: contentWarnings
        )
    }
}

private struct RottenTomatoesStatsDTO: Decodable, Sendable {
    let percentage: Int
    let totalReviews: Int?
    let freshCount: Int?
    let rottenCount: Int?
    let averageScore: Double?
    
    func toStats() -> RottenTomatoesStats {
        RottenTomatoesStats(
            percentage: percentage,
            totalReviews: totalReviews,
            freshCount: freshCount,
            rottenCount: rottenCount,
            averageScore: averageScore
        )
    }
}

private struct EnrichmentDTO: Decodable, Sendable {
    let imdbRating: Double?
    let imdbVotes: Int?
    let metascore: Int?
    let rottenTomatoes: Int?
    let rottenTomatoesStats: RottenTomatoesStatsDTO?
    let runtimeMin: Int?
    let rated: String?
    let released: String?
    let director: String?
    let writer: String?
    let actors: String?
    let awards: String?
    let country: String?
    let language: String?
    let boxOffice: String?
    let production: String?
    let genre: String?

    func toEnrichment() -> MovieEnrichment {
        MovieEnrichment(
            imdbRating: imdbRating,
            imdbVotes: imdbVotes,
            metascore: metascore,
            rottenTomatoes: rottenTomatoes,
            rottenTomatoesStats: rottenTomatoesStats?.toStats(),
            runtimeMin: runtimeMin,
            rated: rated,
            released: released,
            director: director,
            writer: writer,
            actors: actors,
            awards: awards,
            country: country,
            language: language,
            boxOffice: boxOffice,
            production: production,
            genre: genre
        )
    }
}

private struct CreditsBundleDTO: Decodable, Sendable {
    let cast: [TMDBCastDTO]
}

private struct SimilarBundleDTO: Decodable, Sendable {
    let results: [TMDBMovieDTO]
}

private struct ExternalIdsDTO: Decodable, Sendable {
    // Property names are camelCase; the decoder's `convertFromSnakeCase`
    // strategy translates the JSON `imdb_id`/`tvdb_id` keys for us.
    // Do NOT add an explicit `CodingKeys` enum with snake_case raw values
    // here — when combined with `convertFromSnakeCase` it silently breaks
    // decoding (the strategy pre-converts the key to camelCase, then the
    // explicit CodingKey raw value never matches).
    let imdbId: String?
    let tvdbId: Int?
}

private struct VideosBundleDTO: Decodable, Sendable {
    let results: [VideoDTO]

    var youtubeVideos: [MediaVideo] {
        results.compactMap { video in
            guard let key = video.key, video.site?.lowercased() == "youtube" else { return nil }
            return MediaVideo(
                key: key,
                name: video.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? video.name!.trimmingCharacters(in: .whitespacesAndNewlines)
                    : (video.type ?? "Video"),
                type: video.type ?? "Video",
                official: video.official ?? false
            )
        }
    }

    /// Pick the best official trailer / teaser (sorted by type + name; duration refined in UI).
    var preferredTrailerURL: URL? {
        MediaVideo.sortedTrailers(youtubeVideos).first?.youtubeWatchURL
    }
}

private struct VideoDTO: Decodable, Sendable {
    let key: String?
    let name: String?
    let site: String?
    let type: String?
    let official: Bool?
}

private struct TMDBImageDTO: Decodable, Sendable {
    // `file_path` is mapped via the decoder's `convertFromSnakeCase` strategy.
    let filePath: String
}

private struct TVShowSeasonsDTO: Decodable, Sendable {
    let seasons: [TVSeasonListItemDTO]?
}

private struct TVSeasonListItemDTO: Decodable, Sendable {
    // Keys (`season_number`, `episode_count`, `poster_path`) are mapped via
    // the decoder's `convertFromSnakeCase` strategy. See ExternalIdsDTO note.
    let seasonNumber: Int
    let name: String?
    let episodeCount: Int?
    let posterPath: String?
}

private struct TVSeasonDetailDTO: Decodable, Sendable {
    let episodes: [TVEpisodeDTO]?
}

private struct TVEpisodeDTO: Decodable, Sendable {
    // `episode_number` / `still_path` are mapped via `convertFromSnakeCase`.
    let id: Int
    let episodeNumber: Int
    let name: String?
    let overview: String?
    let airDate: String?
    let stillPath: String?
    let runtime: Int?
}

private struct TMDBMovieDTO: Decodable, Sendable {
    let id: Int
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let genreIds: [Int]?
    let runtime: Int?
    let genres: [Genre]?

    var movie: Movie {
        Movie(
            id: id,
            title: title ?? name ?? "Untitled",
            overview: overview ?? "",
            posterPath: posterPath,
            backdropPath: backdropPath,
            releaseDate: releaseDate ?? firstAirDate ?? "",
            voteAverage: voteAverage ?? 0,
            genreIds: genreIds ?? genres?.map(\.id) ?? [],
            runtime: runtime
        )
    }
}

private struct TMDBCastDTO: Decodable, Sendable {
    let id: Int
    let name: String
    let character: String?
    let profilePath: String?

    var castMember: CastMember {
        CastMember(id: id, name: name, character: character ?? "", profilePath: profilePath)
    }
}

public struct SubtitleInfo: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let author: String
    public let language: String
    public let downloadUrl: String

    enum CodingKeys: String, CodingKey {
        case id, name, author, language
        case downloadUrl
        case downloadUrlSnake = "download_url"
    }

    public init(id: String, name: String, author: String, language: String, downloadUrl: String) {
        self.id = id
        self.name = name
        self.author = author
        self.language = language
        self.downloadUrl = downloadUrl
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        author = try container.decode(String.self, forKey: .author)
        language = try container.decode(String.self, forKey: .language)
        downloadUrl =
            try container.decodeIfPresent(String.self, forKey: .downloadUrl)
            ?? container.decode(String.self, forKey: .downloadUrlSnake)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(author, forKey: .author)
        try container.encode(language, forKey: .language)
        try container.encode(downloadUrl, forKey: .downloadUrl)
    }
}

public struct SubtitleSearchResponse: Sendable, Codable {
    public let subtitles: [SubtitleInfo]

    public init(subtitles: [SubtitleInfo]) {
        self.subtitles = subtitles
    }
}

public enum SubtitleError: Error, Sendable, LocalizedError {
    case missingConfiguration
    case invalidURL
    case upstream(Int)
    case noSubtitlesFound

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration: "Missing subtitle service configuration."
        case .invalidURL: "Could not build subtitle request URL."
        case .upstream(let status): "Subtitle service returned HTTP \(status)."
        case .noSubtitlesFound: "No subtitles found."
        }
    }
}

public actor SubtitleClient {
    private let mode: MetadataEndpointMode?
    private let session: URLSession
    private let responseDecoder: JSONDecoder

    public init(mode: MetadataEndpointMode? = nil, session: URLSession = .shared) {
        self.mode = mode
        self.session = session
        self.responseDecoder = JSONDecoder()
    }

    public func searchSubtitles(title: String, year: Int? = nil, language: String = "all", type: String = "movie", imdbId: String? = nil) async throws -> [SubtitleInfo] {
        guard let mode else { throw SubtitleError.missingConfiguration }

        switch mode {
        case .direct:
            throw SubtitleError.missingConfiguration
        case .backend(let baseURL, let appToken):
            let withYear = try await performSubtitleSearch(
                baseURL: baseURL,
                appToken: appToken,
                title: title,
                year: year,
                language: language,
                type: type,
                imdbId: imdbId
            )
            if !withYear.isEmpty || year == nil {
                return withYear
            }
            return try await performSubtitleSearch(
                baseURL: baseURL,
                appToken: appToken,
                title: title,
                year: nil,
                language: language,
                type: type,
                imdbId: imdbId
            )
        }
    }

    private func performSubtitleSearch(
        baseURL: URL,
        appToken: String,
        title: String,
        year: Int?,
        language: String,
        type: String,
        imdbId: String?
    ) async throws -> [SubtitleInfo] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "type", value: type),
        ]
        if let year { queryItems.append(URLQueryItem(name: "year", value: String(year))) }
        if let imdbId {
            let normalized = imdbId.hasPrefix("tt") ? String(imdbId.dropFirst(2)) : imdbId
            queryItems.append(URLQueryItem(name: "imdb_id", value: normalized))
        }

        var components = URLComponents(url: baseURL.appending(path: "api/subtitles/search"), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let builtURL = components?.url else { throw SubtitleError.invalidURL }

        var request = URLRequest(url: builtURL)
        request.setValue(appToken, forHTTPHeaderField: "X-MovieBox-Token")
        request.timeoutInterval = 45
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SubtitleError.upstream(http.statusCode)
        }
        let decoded = try responseDecoder.decode(SubtitleSearchResponse.self, from: data)
        return decoded.subtitles
    }

    public func downloadSubtitle(url: String) async throws -> Data {
        guard let mode else { throw SubtitleError.missingConfiguration }

        let requestURL: URL
        switch mode {
        case .direct:
            throw SubtitleError.missingConfiguration
        case .backend(let baseURL, let appToken):
            var components = URLComponents(url: baseURL.appending(path: "api/subtitles/download"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "url", value: url)]
            guard let builtURL = components?.url else { throw SubtitleError.invalidURL }
            requestURL = builtURL
            var request = URLRequest(url: requestURL)
            request.setValue(appToken, forHTTPHeaderField: "X-MovieBox-Token")
            request.timeoutInterval = 30
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw SubtitleError.upstream(http.statusCode)
            }
            return data
        }
    }
}

import AppKit

public final class DecodedImageCache: @unchecked Sendable {
    public static let shared = DecodedImageCache()
    private let cache = NSCache<NSURL, NSImage>()
    
    private init() {
        cache.countLimit = 150
    }
    
    public func image(for url: URL) -> NSImage? {
        return cache.object(forKey: url as NSURL)
    }
    
    public func insert(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
    
    public func clear() {
        cache.removeAllObjects()
    }
}

public actor MovieRegistry {
    public static let shared = MovieRegistry()
    private var registry: [Int: Movie] = [:]
    private var kinds: [Int: MediaKind] = [:]
    
    public func canonicalize(_ movie: Movie, kind: MediaKind) -> Movie {
        kinds[movie.id] = kind
        if let existing = registry[movie.id] {
            let merged = mergedMovie(existing, with: movie)
            registry[movie.id] = merged
            return merged
        } else {
            registry[movie.id] = movie
            return movie
        }
    }
    
    public func canonicalize(_ list: [Movie], kind: MediaKind) -> [Movie] {
        return list.map { canonicalize($0, kind: kind) }
    }
    
    public func allMovies() -> [Movie] {
        return Array(registry.values)
    }
    
    public func kind(for id: Int) -> MediaKind? {
        return kinds[id]
    }
    
    private func mergedMovie(_ primary: Movie, with fallback: Movie) -> Movie {
        Movie(
            id: primary.id,
            title: primary.title.isEmpty ? fallback.title : primary.title,
            overview: primary.overview.isEmpty ? fallback.overview : primary.overview,
            posterPath: primary.posterPath ?? fallback.posterPath,
            backdropPath: primary.backdropPath ?? fallback.backdropPath,
            releaseDate: primary.releaseDate.isEmpty ? fallback.releaseDate : primary.releaseDate,
            voteAverage: max(primary.voteAverage, fallback.voteAverage),
            genreIds: primary.genreIds.isEmpty ? fallback.genreIds : primary.genreIds,
            runtime: primary.runtime ?? fallback.runtime
        )
    }
}

public actor MovieDetailCache {
    public static let shared = MovieDetailCache()
    private var detailCache: [String: MovieDetail] = [:]
    private var seasonsCache: [Int: [TVSeasonSummary]] = [:]
    private var episodesCache: [String: [TVEpisode]] = [:] // key: "showId:seasonNumber"
    
    public func detail(id: Int, kind: MediaKind) -> MovieDetail? {
        let key = "\(kind.rawValue):\(id)"
        return detailCache[key]
    }
    
    public func insertDetail(_ detail: MovieDetail, id: Int, kind: MediaKind) {
        let key = "\(kind.rawValue):\(id)"
        detailCache[key] = detail
    }
    
    public func tvSeasons(showId: Int) -> [TVSeasonSummary]? {
        return seasonsCache[showId]
    }
    
    public func insertTVSeasons(_ seasons: [TVSeasonSummary], showId: Int) {
        seasonsCache[showId] = seasons
    }
    
    public func tvEpisodes(showId: Int, season: Int) -> [TVEpisode]? {
        let key = "\(showId):\(season)"
        return episodesCache[key]
    }
    
    public func insertTVEpisodes(_ episodes: [TVEpisode], showId: Int, season: Int) {
        let key = "\(showId):\(season)"
        episodesCache[key] = episodes
    }
    
    public func clear() {
        detailCache.removeAll()
        seasonsCache.removeAll()
        episodesCache.removeAll()
    }
}

public struct CachedImageView<Content: View, Placeholder: View>: View {
    let url: URL?
    let loader: ImageLoader
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let content: (Image) -> Content

    @State private var image: Image?

    public init(
        url: URL?,
        loader: ImageLoader? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder content: @escaping (Image) -> Content
    ) {
        self.url = url
        self.loader = loader ?? ImageLoader.shared()
        self.placeholder = placeholder
        self.content = content
        
        if let url = url, let cachedImage = DecodedImageCache.shared.image(for: url) {
            self._image = State(initialValue: Image(nsImage: cachedImage))
        } else {
            self._image = State(initialValue: nil)
        }
    }

    public var body: some View {
        Group {
            if let image {
                content(image)
            } else {
                placeholder()
                    .task { await loadImage() }
            }
        }
    }

    private func loadImage() async {
        guard let url else { return }
        if let cached = DecodedImageCache.shared.image(for: url) {
            await MainActor.run {
                image = Image(nsImage: cached)
            }
            return
        }
        do {
            let data = try await loader.data(for: url)
            guard let nsImage = NSImage(data: data) else { return }
            DecodedImageCache.shared.insert(nsImage, for: url)
            await MainActor.run {
                image = Image(nsImage: nsImage)
            }
        } catch {
            // Image failed to load, keep placeholder
        }
    }
}
