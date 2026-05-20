import CoreMetadata
import Foundation

public actor CatalogCache {
    public static let shared = CatalogCache()
    
    private var cachedHomePayload: HomeCatalogPayload?
    private var homePayloadTime: Date?
    
    private var cachedCatalogPayloads: [String: CatalogPayload] = [:]
    private var catalogPayloadTimes: [String: Date] = [:]
    
    private let cacheDuration: TimeInterval = 300 // 5 minutes cache TTL
    
    public func getHomePayload() -> HomeCatalogPayload? {
        guard let time = homePayloadTime, Date().timeIntervalSince(time) < cacheDuration else {
            return nil
        }
        return cachedHomePayload
    }
    
    public func setHomePayload(_ payload: HomeCatalogPayload) {
        cachedHomePayload = payload
        homePayloadTime = Date()
    }
    
    public func getCatalogPayload(kind: MediaKind) -> CatalogPayload? {
        let key = kind.rawValue
        guard let time = catalogPayloadTimes[key], Date().timeIntervalSince(time) < cacheDuration else {
            return nil
        }
        return cachedCatalogPayloads[key]
    }
    
    public func setCatalogPayload(_ payload: CatalogPayload, kind: MediaKind) {
        let key = kind.rawValue
        cachedCatalogPayloads[key] = payload
        catalogPayloadTimes[key] = Date()
    }
    
    public func clear() {
        cachedHomePayload = nil
        homePayloadTime = nil
        cachedCatalogPayloads.removeAll()
        catalogPayloadTimes.removeAll()
    }
}

public struct HomeCatalogPayload: Sendable {
    public let rows: [MetadataCategory: [Movie]]
    public let kindsByID: [Int: MediaKind]
    public let extraSections: [HomeExtraSection]

    public init(
        rows: [MetadataCategory: [Movie]],
        kindsByID: [Int: MediaKind],
        extraSections: [HomeExtraSection] = []
    ) {
        self.rows = rows
        self.kindsByID = kindsByID
        self.extraSections = extraSections
    }
}

public struct HomeExtraSection: Sendable {
    public let id: String
    public let title: String
    public let items: [Movie]
    public let kindByID: [Int: MediaKind]

    public init(id: String, title: String, items: [Movie], kindByID: [Int: MediaKind]) {
        self.id = id
        self.title = title
        self.items = items
        self.kindByID = kindByID
    }
}

public struct CatalogPayload: Sendable {
    public let rows: [MetadataCategory: [Movie]]
    public let extraSections: [HomeExtraSection]

    public init(rows: [MetadataCategory: [Movie]], extraSections: [HomeExtraSection] = []) {
        self.rows = rows
        self.extraSections = extraSections
    }
}

public enum CatalogLoader {
    private static func interleave(_ movies: [Movie], _ tv: [Movie]) -> [Movie] {
        let total = max(movies.count, tv.count)
        var output: [Movie] = []
        output.reserveCapacity(movies.count + tv.count)
        for i in 0..<total {
            if i < movies.count { output.append(movies[i]) }
            if i < tv.count { output.append(tv[i]) }
        }
        return output
    }

    private static func mergedMovie(_ primary: Movie, with fallback: Movie) -> Movie {
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

    private static func canonicalMap(from lists: [[Movie]]) -> [Int: Movie] {
        var map: [Int: Movie] = [:]
        for list in lists {
            for movie in list {
                if let existing = map[movie.id] {
                    map[movie.id] = mergedMovie(existing, with: movie)
                } else {
                    map[movie.id] = movie
                }
            }
        }
        return map
    }

    private static func hydrate(_ list: [Movie], using canonical: [Int: Movie]) -> [Movie] {
        list.map { canonical[$0.id] ?? $0 }
    }

    private static func collectAwardCandidates(
        client: MetadataClient,
        kind: MediaKind,
        keywordQueries: [String],
        pagesPerKeyword: Int = 2
    ) async -> [Movie] {
        var byID: [Int: Movie] = [:]

        for query in keywordQueries {
            guard let keywordID = (try? await client.keywordID(matching: query)) ?? nil else { continue }
            for page in 1...max(1, pagesPerKeyword) {
                guard let hits = try? await client.discoverByKeyword(kind: kind, keywordID: keywordID, page: page) else {
                    continue
                }
                for movie in hits {
                    if let existing = byID[movie.id] {
                        byID[movie.id] = mergedMovie(existing, with: movie)
                    } else {
                        byID[movie.id] = movie
                    }
                }
            }
        }

        return byID.values.sorted { lhs, rhs in
            if lhs.voteAverage == rhs.voteAverage {
                return lhs.releaseDate > rhs.releaseDate
            }
            return lhs.voteAverage > rhs.voteAverage
        }
    }

    public static func loadRows(mode: MetadataEndpointMode, kind: MediaKind) async throws -> [MetadataCategory: [Movie]] {
        let payload = try await loadCatalogPayload(mode: mode, kind: kind)
        return payload.rows
    }

    public static func loadCatalogPayload(mode: MetadataEndpointMode, kind: MediaKind) async throws -> CatalogPayload {
        var last: CatalogPayload?
        for try await payload in loadCatalogPayloadStream(mode: mode, kind: kind) {
            last = payload
        }
        guard let last else {
            throw CancellationError()
        }
        return last
    }

    /// Yields at least twice: first when core category rows are ready, again when extra shelves have been merged in.
    public static func loadCatalogPayloadStream(mode: MetadataEndpointMode, kind: MediaKind) -> AsyncThrowingStream<CatalogPayload, Error> {
        AsyncThrowingStream(CatalogPayload.self, bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    if let cached = await CatalogCache.shared.getCatalogPayload(kind: kind) {
                        continuation.yield(cached)
                        continuation.finish()
                        return
                    }
                    let client = MetadataClient(mode: mode)
                    async let trending = client.movies(for: .trending, kind: kind)
                    async let popular = client.movies(for: .popular, kind: kind)
                    async let topRated = client.movies(for: .topRated, kind: kind)
                    async let nowPlaying = client.movies(for: .nowPlaying, kind: kind)
                    let trendingList = try await trending
                    let popularList = try await popular
                    let topRatedList = try await topRated
                    let nowPlayingList = try await nowPlaying

                    let canonical = canonicalMap(from: [trendingList, popularList, topRatedList, nowPlayingList])
                    let rows: [MetadataCategory: [Movie]] = [
                        .trending: hydrate(trendingList, using: canonical),
                        .popular: hydrate(popularList, using: canonical),
                        .topRated: hydrate(topRatedList, using: canonical),
                        .nowPlaying: hydrate(nowPlayingList, using: canonical),
                    ]
                    continuation.yield(CatalogPayload(rows: rows, extraSections: []))

                    let fullPayload = try await loadCatalogExtraSections(
                        client: client,
                        kind: kind,
                        canonical: canonical,
                        baseRows: rows
                    )
                    await CatalogCache.shared.setCatalogPayload(fullPayload, kind: kind)
                    continuation.yield(fullPayload)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Fetches curated extra sections for catalog (same shelves as `loadCatalogPayload` after core rows).
    private static func loadCatalogExtraSections(
        client: MetadataClient,
        kind: MediaKind,
        canonical: [Int: Movie],
        baseRows: [MetadataCategory: [Movie]]
    ) async throws -> CatalogPayload {
        let extraSections: [HomeExtraSection]
        switch kind {
        case .movie:
            async let blockbustersTask = client.discoverCurated(
                kind: .movie,
                queryItems: [
                    URLQueryItem(name: "sort_by", value: "popularity.desc"),
                    URLQueryItem(name: "vote_count.gte", value: "1800"),
                ]
            )
            async let criticallyAcclaimedTask = client.discoverCurated(
                kind: .movie,
                queryItems: [
                    URLQueryItem(name: "sort_by", value: "vote_average.desc"),
                    URLQueryItem(name: "vote_count.gte", value: "2500"),
                ]
            )
            async let hiddenGemsTask = client.discoverCurated(
                kind: .movie,
                queryItems: [
                    URLQueryItem(name: "sort_by", value: "vote_average.desc"),
                    URLQueryItem(name: "vote_average.gte", value: "7.0"),
                    URLQueryItem(name: "vote_count.gte", value: "100"),
                    URLQueryItem(name: "vote_count.lte", value: "1400"),
                ]
            )
            async let oscarCandidatesTask = collectAwardCandidates(
                client: client,
                kind: .movie,
                keywordQueries: [
                    "academy award winner",
                    "academy award",
                    "oscar winner",
                    "best picture winner",
                ]
            )

            var sections: [HomeExtraSection] = []

            if let blockbusters = try? await blockbustersTask, !blockbusters.isEmpty {
                let hydrated = hydrate(blockbusters, using: canonical)
                sections.append(
                    HomeExtraSection(
                        id: "movie-blockbusters",
                        title: "Blockbuster Movies",
                        items: Array(hydrated.prefix(20)),
                        kindByID: Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, MediaKind.movie) })
                    )
                )
            }

            if let acclaimed = try? await criticallyAcclaimedTask, !acclaimed.isEmpty {
                let hydrated = hydrate(acclaimed, using: canonical)
                sections.append(
                    HomeExtraSection(
                        id: "movie-critically-acclaimed",
                        title: "Critically Acclaimed",
                        items: Array(hydrated.prefix(20)),
                        kindByID: Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, MediaKind.movie) })
                    )
                )
            }

            if let hiddenGems = try? await hiddenGemsTask, !hiddenGems.isEmpty {
                let hydrated = hydrate(hiddenGems, using: canonical)
                sections.append(
                    HomeExtraSection(
                        id: "movie-hidden-gems",
                        title: "Hidden Gems",
                        items: Array(hydrated.prefix(20)),
                        kindByID: Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, MediaKind.movie) })
                    )
                )
            }

            if let winners = try? await oscarCandidatesTask, !winners.isEmpty {
                let hydrated = hydrate(winners, using: canonical)
                sections.append(
                    HomeExtraSection(
                        id: "movie-oscar-winners",
                        title: "Oscar Nominees",
                        items: Array(hydrated.prefix(20)),
                        kindByID: Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, MediaKind.movie) })
                    )
                )
            }

            extraSections = sections

        case .tv:
            async let bingeWorthyTask = client.discoverCurated(
                kind: .tv,
                queryItems: [
                    URLQueryItem(name: "sort_by", value: "popularity.desc"),
                    URLQueryItem(name: "vote_count.gte", value: "700"),
                ]
            )
            async let crimeMysteryTask = client.discoverCurated(
                kind: .tv,
                queryItems: [
                    URLQueryItem(name: "with_genres", value: "80,9648"),
                    URLQueryItem(name: "sort_by", value: "popularity.desc"),
                ]
            )
            async let sciFiFantasyTask = client.discoverCurated(
                kind: .tv,
                queryItems: [
                    URLQueryItem(name: "with_genres", value: "10765"),
                    URLQueryItem(name: "sort_by", value: "popularity.desc"),
                    URLQueryItem(name: "vote_count.gte", value: "200"),
                ]
            )
            async let emmyCandidatesTask = collectAwardCandidates(
                client: client,
                kind: .tv,
                keywordQueries: [
                    "emmy award winner",
                    "emmy winner",
                    "primetime emmy award winner",
                ]
            )

            var sections: [HomeExtraSection] = []

            if let bingeWorthy = try? await bingeWorthyTask, !bingeWorthy.isEmpty {
                let hydrated = hydrate(bingeWorthy, using: canonical)
                sections.append(
                    HomeExtraSection(
                        id: "tv-binge-worthy",
                        title: "Binge-Worthy Shows",
                        items: Array(hydrated.prefix(20)),
                        kindByID: Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, MediaKind.tv) })
                    )
                )
            }

            if let crimeMystery = try? await crimeMysteryTask, !crimeMystery.isEmpty {
                let hydrated = hydrate(crimeMystery, using: canonical)
                sections.append(
                    HomeExtraSection(
                        id: "tv-crime-mystery",
                        title: "Crime & Mystery",
                        items: Array(hydrated.prefix(20)),
                        kindByID: Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, MediaKind.tv) })
                    )
                )
            }

            if let sciFiFantasy = try? await sciFiFantasyTask, !sciFiFantasy.isEmpty {
                let hydrated = hydrate(sciFiFantasy, using: canonical)
                sections.append(
                    HomeExtraSection(
                        id: "tv-sci-fi-fantasy",
                        title: "Sci-Fi & Fantasy Hits",
                        items: Array(hydrated.prefix(20)),
                        kindByID: Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, MediaKind.tv) })
                    )
                )
            }

            if let winners = try? await emmyCandidatesTask, !winners.isEmpty {
                let hydrated = hydrate(winners, using: canonical)
                sections.append(
                    HomeExtraSection(
                        id: "tv-emmy-winners",
                        title: "Emmy Winners",
                        items: Array(hydrated.prefix(20)),
                        kindByID: Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, MediaKind.tv) })
                    )
                )
            }

            extraSections = sections
        }

        return CatalogPayload(rows: baseRows, extraSections: extraSections)
    }

    public static func loadHomeRows(mode: MetadataEndpointMode) async throws -> [MetadataCategory: [Movie]] {
        let payload = try await loadHomePayload(mode: mode)
        return payload.rows
    }

    public static func loadHomePayload(mode: MetadataEndpointMode) async throws -> HomeCatalogPayload {
        var last: HomeCatalogPayload?
        for try await payload in loadHomePayloadStream(mode: mode) {
            last = payload
        }
        guard let last else {
            throw CancellationError()
        }
        return last
    }

    /// Yields at least twice: first when core category rows are ready, again when extra shelves have been merged in.
    public static func loadHomePayloadStream(mode: MetadataEndpointMode) -> AsyncThrowingStream<HomeCatalogPayload, Error> {
        AsyncThrowingStream(HomeCatalogPayload.self, bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    if let cached = await CatalogCache.shared.getHomePayload() {
                        continuation.yield(cached)
                        continuation.finish()
                        return
                    }
                    let client = MetadataClient(mode: mode)

                    async let moviesTrending = client.movies(for: .trending, kind: .movie)
                    async let moviesPopular = client.movies(for: .popular, kind: .movie)
                    async let moviesTopRated = client.movies(for: .topRated, kind: .movie)
                    async let moviesNowPlaying = client.movies(for: .nowPlaying, kind: .movie)

                    async let tvTrending = client.movies(for: .trending, kind: .tv)
                    async let tvPopular = client.movies(for: .popular, kind: .tv)
                    async let tvTopRated = client.movies(for: .topRated, kind: .tv)

                    let movieTrendingList = try await moviesTrending
                    let moviePopularList = try await moviesPopular
                    let movieTopRatedList = try await moviesTopRated
                    let movieNowPlayingList = try await moviesNowPlaying
                    let tvTrendingList = try await tvTrending
                    let tvPopularList = try await tvPopular
                    let tvTopRatedList = try await tvTopRated

                    let movieCanonical = canonicalMap(from: [movieTrendingList, moviePopularList, movieTopRatedList, movieNowPlayingList])
                    let tvCanonical = canonicalMap(from: [tvTrendingList, tvPopularList, tvTopRatedList])
                    let hydratedMovieTrending = hydrate(movieTrendingList, using: movieCanonical)
                    let hydratedMoviePopular = hydrate(moviePopularList, using: movieCanonical)
                    let hydratedMovieTopRated = hydrate(movieTopRatedList, using: movieCanonical)
                    let hydratedMovieNowPlaying = hydrate(movieNowPlayingList, using: movieCanonical)
                    let hydratedTvTrending = hydrate(tvTrendingList, using: tvCanonical)
                    let hydratedTvPopular = hydrate(tvPopularList, using: tvCanonical)
                    let hydratedTvTopRated = hydrate(tvTopRatedList, using: tvCanonical)

                    var kindsByID: [Int: MediaKind] = [:]
                    for movie in hydratedMovieTrending + hydratedMoviePopular + hydratedMovieTopRated + hydratedMovieNowPlaying {
                        kindsByID[movie.id] = .movie
                    }
                    for show in hydratedTvTrending + hydratedTvPopular + hydratedTvTopRated {
                        kindsByID[show.id] = .tv
                    }

                    let rows: [MetadataCategory: [Movie]] = [
                        .trending: interleave(hydratedMovieTrending, hydratedTvTrending),
                        .popular: interleave(hydratedMoviePopular, hydratedTvPopular),
                        .topRated: interleave(hydratedMovieTopRated, hydratedTvTopRated),
                        .nowPlaying: hydratedMovieNowPlaying,
                    ]

                    continuation.yield(HomeCatalogPayload(rows: rows, kindsByID: kindsByID, extraSections: []))

                    async let criticallyAcclaimedTask = client.discoverCurated(
                        kind: .movie,
                        queryItems: [
                            URLQueryItem(name: "sort_by", value: "vote_average.desc"),
                            URLQueryItem(name: "vote_count.gte", value: "2500"),
                        ]
                    )
                    async let bingeWorthyShowsTask = client.discoverCurated(
                        kind: .tv,
                        queryItems: [
                            URLQueryItem(name: "sort_by", value: "popularity.desc"),
                            URLQueryItem(name: "vote_count.gte", value: "750"),
                        ]
                    )
                    async let oscarCandidatesTask = collectAwardCandidates(
                        client: client,
                        kind: .movie,
                        keywordQueries: [
                            "academy award winner",
                            "academy award",
                            "oscar winner",
                            "best picture winner",
                        ]
                    )

                    var extraSections: [HomeExtraSection] = []

                    if let critically = try? await criticallyAcclaimedTask, !critically.isEmpty {
                        let hydrated = hydrate(critically, using: movieCanonical)
                        extraSections.append(
                            HomeExtraSection(
                                id: "critically-acclaimed",
                                title: "Critically Acclaimed",
                                items: Array(hydrated.prefix(20)),
                                kindByID: Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, MediaKind.movie) })
                            )
                        )
                    }

                    if let bingeShows = try? await bingeWorthyShowsTask, !bingeShows.isEmpty {
                        let hydrated = hydrate(bingeShows, using: tvCanonical)
                        extraSections.append(
                            HomeExtraSection(
                                id: "binge-worthy-shows",
                                title: "Binge-Worthy Shows",
                                items: Array(hydrated.prefix(20)),
                                kindByID: Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, MediaKind.tv) })
                            )
                        )
                    }

                    if let oscarWinners = try? await oscarCandidatesTask,
                       !oscarWinners.isEmpty {
                        let hydrated = hydrate(oscarWinners, using: movieCanonical)
                        extraSections.append(
                            HomeExtraSection(
                                id: "oscar-winners",
                                title: "Oscar Nominees",
                                items: Array(hydrated.prefix(20)),
                                kindByID: Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, MediaKind.movie) })
                            )
                        )
                    }

                    let finalPayload = HomeCatalogPayload(rows: rows, kindsByID: kindsByID, extraSections: extraSections)
                    await CatalogCache.shared.setHomePayload(finalPayload)
                    continuation.yield(finalPayload)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
