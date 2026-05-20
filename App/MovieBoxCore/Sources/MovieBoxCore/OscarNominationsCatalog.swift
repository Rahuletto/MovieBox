import CoreMetadata
import Foundation

/// Curated Oscar nominees from [json-nominations](https://github.com/delventhalz/json-nominations).
/// Uses Best Picture rows (each nominee film includes `tmdb_id`) for the latest ceremony year in the dataset.
public enum OscarNominationsCatalog {
    private static let sourceURL = URL(
        string: "https://raw.githubusercontent.com/delventhalz/json-nominations/refs/heads/main/oscar-nominations.json"
    )!

    private static let bestPictureCategory = "Best Picture"

    private struct NominationRecord: Decodable, Sendable {
        let category: String
        let year: String
        let movies: [NominationMovie]?
    }

    private struct NominationMovie: Decodable, Sendable {
        let title: String
        let tmdbId: Int?
    }

    /// TMDB ids for Best Picture nominees in the newest Oscar year present in the JSON feed.
    public static func latestBestPictureNomineeIDs() async -> [Int] {
        guard let records = await loadRecords() else { return [] }
        let bestPicture = records.filter { $0.category == bestPictureCategory }
        guard let latestYear = bestPicture.map(\.year).max() else { return [] }

        var seen = Set<Int>()
        var ordered: [Int] = []
        for record in bestPicture where record.year == latestYear {
            for movie in record.movies ?? [] {
                guard let id = movie.tmdbId, id > 0, seen.insert(id).inserted else { continue }
                ordered.append(id)
            }
        }
        return ordered
    }

    /// Resolves nominee ids to TMDB movies (up to `shelfLimit`). Falls back to keyword discovery when the feed is unavailable.
    public static func moviesForShelf(
        client: MetadataClient,
        canonical: [Int: Movie],
        limit: Int = 20
    ) async -> [Movie] {
        let ids = await latestBestPictureNomineeIDs()
        if !ids.isEmpty, let resolved = await resolveMovies(client: client, ids: ids, limit: limit) {
            return hydrate(resolved, using: canonical)
        }
        return await keywordFallback(client: client, canonical: canonical, limit: limit)
    }

    private static func loadRecords() async -> [NominationRecord]? {
        var request = URLRequest(url: sourceURL)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 25
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode([NominationRecord].self, from: data)
        } catch {
            return nil
        }
    }

    private static func resolveMovies(
        client: MetadataClient,
        ids: [Int],
        limit: Int
    ) async -> [Movie]? {
        var movies: [Movie] = []
        movies.reserveCapacity(min(limit, ids.count))

        for id in ids.prefix(limit * 2) {
            if movies.count >= limit { break }
            if let movie = try? await client.movieSummary(id: id, kind: .movie) {
                movies.append(movie)
            }
        }
        return movies.isEmpty ? nil : movies
    }

    private static func hydrate(_ list: [Movie], using canonical: [Int: Movie]) -> [Movie] {
        list.map { canonical[$0.id] ?? $0 }
    }

    private static func keywordFallback(
        client: MetadataClient,
        canonical: [Int: Movie],
        limit: Int
    ) async -> [Movie] {
        var byID: [Int: Movie] = [:]
        let queries = [
            "academy award winner",
            "academy award",
            "oscar winner",
            "best picture winner",
        ]
        for query in queries {
            guard let keywordID = (try? await client.keywordID(matching: query)) ?? nil else { continue }
            guard let hits = try? await client.discoverByKeyword(kind: .movie, keywordID: keywordID, page: 1) else {
                continue
            }
            for movie in hits {
                byID[movie.id] = movie
            }
        }
        let sorted = byID.values.sorted { lhs, rhs in
            if lhs.voteAverage == rhs.voteAverage {
                return lhs.releaseDate > rhs.releaseDate
            }
            return lhs.voteAverage > rhs.voteAverage
        }
        return hydrate(Array(sorted.prefix(limit)), using: canonical)
    }
}
