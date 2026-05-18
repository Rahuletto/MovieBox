import Foundation
import SwiftUI

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
public struct MovieEnrichment: Sendable, Codable, Hashable {
    public let imdbRating: Double?       // 7.8
    public let imdbVotes: Int?           // 1_234_567
    public let metascore: Int?           // 74 (out of 100)
    public let rottenTomatoes: Int?      // 91 (percent)
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
}

public struct MovieDetail: Sendable, Codable, Identifiable, Hashable {
    public var id: Int { movie.id }
    public let movie: Movie
    public let genres: [Genre]
    public let cast: [CastMember]
    public let trailerURL: URL?
    public let similar: [Movie]
    /// Pre-resolved fanart logo (returned by the backend bundle endpoint).
    /// When non-nil, `AsyncLogoView` will skip its own network fetch.
    public let logoURL: URL?
    /// IMDb id pulled from TMDB external_ids — useful for subtitle / OMDb lookups
    /// without doing another /external_ids call.
    public let imdbId: String?
    /// OMDB-sourced enrichment (IMDB rating, RT, Metascore, director, awards…).
    public let enrichment: MovieEnrichment?

    public init(
        movie: Movie,
        genres: [Genre],
        cast: [CastMember] = [],
        trailerURL: URL? = nil,
        similar: [Movie] = [],
        logoURL: URL? = nil,
        imdbId: String? = nil,
        enrichment: MovieEnrichment? = nil
    ) {
        self.movie = movie
        self.genres = genres
        self.cast = cast
        self.trailerURL = trailerURL
        self.similar = similar
        self.logoURL = logoURL
        self.imdbId = imdbId
        self.enrichment = enrichment
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
    public let stillPath: String?
    public let runtime: Int?

    public init(
        id: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        name: String,
        overview: String,
        stillPath: String?,
        runtime: Int?
    ) {
        self.id = id
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.name = name
        self.overview = overview
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

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration: "Missing metadata API configuration."
        case .invalidURL: "Could not build metadata request URL."
        case .upstream(let status): "Metadata service returned HTTP \(status)."
        }
    }
}

public actor MetadataClient {
    private let mode: MetadataEndpointMode?
    private let session: URLSession
    private let decoder: JSONDecoder
    private let tmdbToken: String?

    public init(mode: MetadataEndpointMode? = nil, session: URLSession = .shared, tmdbToken: String? = nil) {
        self.mode = mode
        self.session = session
        self.tmdbToken = tmdbToken
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    public func movies(for category: MetadataCategory, kind: MediaKind = .movie, page: Int = 1) async throws -> [Movie] {
        let response: MovieListResponse = try await request(path: category.tmdbPath(kind: kind), queryItems: [URLQueryItem(name: "page", value: String(page))])
        return response.results.map(\.movie)
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
        return response.results.map(\.movie)
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
        return response.results.map(\.movie)
    }

    public func movieDetail(id: Int, kind: MediaKind = .movie) async throws -> MovieDetail {
        guard let mode else { throw MetadataError.missingConfiguration }

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
            let detail = bundle.detail(kind: kind)

            // Pre-seed LogoCache so AsyncLogoView in the detail header skips its fetch.
            if let logoURL = detail.logoURL {
                await LogoCache.shared.seed(kind: kind, id: id, url: logoURL)
            } else {
                // Negative result is also worth seeding so we don't re-resolve.
                await LogoCache.shared.seed(kind: kind, id: id, url: nil)
            }
            return detail
        }

        // Direct mode (no backend): fall back to the three individual TMDB calls.
        let base = kind == .movie ? "/movie" : "/tv"
        async let movieResponse: TMDBMovieDTO = request(path: "\(base)/\(id)")
        async let creditsResponse: CreditsResponse = request(path: "\(base)/\(id)/credits")
        async let similarResponse: MovieListResponse = request(path: "\(base)/\(id)/similar")

        let movie = try await movieResponse.movie
        let credits = try await creditsResponse.cast.prefix(16).map(\.castMember)
        let similar = try await similarResponse.results.map(\.movie)
        return MovieDetail(movie: movie, genres: try await movieResponse.genres ?? [], cast: Array(credits), similar: similar)
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
                    stillPath: $0.stillPath,
                    runtime: $0.runtime
                )
            }
    }

    public func resolveTrailer(key: String) async throws -> URL {
        guard let mode else { throw MetadataError.missingConfiguration }

        if case .backend(let baseURL, let appToken) = mode {
            var components = URLComponents(url: baseURL.appending(path: "api/trailer/resolve"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "key", value: key)]
            guard let url = components?.url else { throw MetadataError.invalidURL }

            var request = URLRequest(url: url)
            request.setValue(appToken, forHTTPHeaderField: "X-MovieBox-Token")
            request.timeoutInterval = 20

            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw MetadataError.upstream(http.statusCode)
            }

            struct TrailerResponse: Codable {
                let url: String
            }
            let resolved = try JSONDecoder().decode(TrailerResponse.self, from: data)
            if let resultURL = URL(string: resolved.url) {
                return resultURL
            }
        }

        // Direct mode fallback
        let apiURL = URL(string: "https://pipedapi.kavin.rocks/streams/\(key)")!
        let (data, _) = try await session.data(from: apiURL)
        
        struct PipedResponse: Codable {
            let hlsUrl: String?
        }
        let piped = try JSONDecoder().decode(PipedResponse.self, from: data)
        if let hls = piped.hlsUrl, let resultURL = URL(string: hls) {
            return resultURL
        }
        
        throw MetadataError.upstream(404)
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
    /// OMDB-sourced enrichment payload (ratings, director, awards, etc.).
    /// This is the *only* place OMDB-derived data enters the type system.
    let movieboxEnrichment: EnrichmentDTO?

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

        return MovieDetail(
            movie: movie,
            genres: genres ?? [],
            cast: Array(cast),
            trailerURL: trailer,
            similar: similarMovies,
            logoURL: movieboxLogo.flatMap(URL.init(string:)),
            imdbId: resolvedImdbId,
            enrichment: movieboxEnrichment?.toEnrichment()
        )
    }
}

private struct EnrichmentDTO: Decodable, Sendable {
    let imdbRating: Double?
    let imdbVotes: Int?
    let metascore: Int?
    let rottenTomatoes: Int?
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

    /// Pick the first official YouTube trailer; fall back to any trailer / teaser.
    var preferredTrailerURL: URL? {
        let trailers = results.filter { $0.site?.lowercased() == "youtube" && $0.key != nil }
        let chosen = trailers.first(where: { ($0.type ?? "").lowercased() == "trailer" && ($0.official ?? false) })
            ?? trailers.first(where: { ($0.type ?? "").lowercased() == "trailer" })
            ?? trailers.first(where: { ($0.type ?? "").lowercased() == "teaser" })
            ?? trailers.first
        guard let key = chosen?.key else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(key)")
    }
}

private struct VideoDTO: Decodable, Sendable {
    let key: String?
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
            releaseDate: releaseDate ?? "",
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

    public init(id: String, name: String, author: String, language: String, downloadUrl: String) {
        self.id = id
        self.name = name
        self.author = author
        self.language = language
        self.downloadUrl = downloadUrl
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
    private let decoder: JSONDecoder

    public init(mode: MetadataEndpointMode? = nil, session: URLSession = .shared) {
        self.mode = mode
        self.session = session
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    public func searchSubtitles(title: String, year: Int? = nil, language: String = "en", type: String = "movie", imdbId: String? = nil) async throws -> [SubtitleInfo] {
        guard let mode else { throw SubtitleError.missingConfiguration }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "type", value: type),
        ]
        if let year { queryItems.append(URLQueryItem(name: "year", value: String(year))) }
        if let imdbId { queryItems.append(URLQueryItem(name: "imdb_id", value: imdbId)) }

        let url: URL
        switch mode {
        case .direct:
            throw SubtitleError.missingConfiguration
        case .backend(let baseURL, let appToken):
            var components = URLComponents(url: baseURL.appending(path: "api/subtitles/search"), resolvingAgainstBaseURL: false)
            components?.queryItems = queryItems
            guard let builtURL = components?.url else { throw SubtitleError.invalidURL }
            url = builtURL
            var request = URLRequest(url: url)
            request.setValue(appToken, forHTTPHeaderField: "X-MovieBox-Token")
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw SubtitleError.upstream(http.statusCode)
            }
            let decoded = try decoder.decode(SubtitleSearchResponse.self, from: data)
            return decoded.subtitles
        }
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
        do {
            let data = try await loader.data(for: url)
            guard let nsImage = NSImage(data: data) else { return }
            await MainActor.run {
                image = Image(nsImage: nsImage)
            }
        } catch {
            // Image failed to load, keep placeholder
        }
    }
}
