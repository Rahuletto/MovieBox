import Foundation
import SwiftUI

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
    public var imdbRating: String?
    public var imdbId: String?

    public init(
        id: Int,
        title: String,
        overview: String,
        posterPath: String?,
        backdropPath: String?,
        releaseDate: String,
        voteAverage: Double,
        genreIds: [Int],
        runtime: Int? = nil,
        imdbRating: String? = nil,
        imdbId: String? = nil
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
        self.imdbRating = imdbRating
        self.imdbId = imdbId
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

public struct MovieDetail: Sendable, Codable, Identifiable, Hashable {
    public var id: Int { movie.id }
    public let movie: Movie
    public let genres: [Genre]
    public let cast: [CastMember]
    public let trailerURL: URL?
    public let similar: [Movie]

    public init(movie: Movie, genres: [Genre], cast: [CastMember] = [], trailerURL: URL? = nil, similar: [Movie] = []) {
        self.movie = movie
        self.genres = genres
        self.cast = cast
        self.trailerURL = trailerURL
        self.similar = similar
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

    public init(mode: MetadataEndpointMode? = nil, session: URLSession = .shared) {
        self.mode = mode
        self.session = session
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
        let base = kind == .movie ? "/movie" : "/tv"
        async let movieResponse: TMDBMovieDTO = request(path: "\(base)/\(id)")
        async let creditsResponse: CreditsResponse = request(path: "\(base)/\(id)/credits")
        async let similarResponse: MovieListResponse = request(path: "\(base)/\(id)/similar")

        let movie = try await movieResponse.movie
        let credits = try await creditsResponse.cast.prefix(16).map(\.castMember)
        let similar = try await similarResponse.results.map(\.movie)
        return MovieDetail(movie: movie, genres: try await movieResponse.genres ?? [], cast: Array(credits), similar: similar)
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
