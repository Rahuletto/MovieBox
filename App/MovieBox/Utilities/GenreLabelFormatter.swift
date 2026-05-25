import CoreMetadata

enum GenreLabelFormatter {
    private static let movieGenres: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime",
        99: "Documentary", 18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History",
        27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance", 878: "Sci-Fi",
        10770: "TV Movie", 53: "Thriller", 10752: "War", 37: "Western"
    ]

    private static let tvGenres: [Int: String] = [
        10759: "Action & Adventure", 16: "Animation", 35: "Comedy", 80: "Crime",
        99: "Documentary", 18: "Drama", 10751: "Family", 10762: "Kids", 9648: "Mystery",
        10763: "News", 10764: "Reality", 10765: "Sci-Fi & Fantasy", 10766: "Soap",
        10767: "Talk", 37: "Western"
    ]

    static func name(id: Int, kind: MediaKind) -> String? {
        switch kind {
        case .movie: movieGenres[id]
        case .tv: tvGenres[id] ?? movieGenres[id]
        }
    }

    static func names(for genreIds: [Int], kind: MediaKind, limit: Int = 2) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for id in genreIds {
            guard let name = name(id: id, kind: kind), !seen.contains(name) else { continue }
            seen.insert(name)
            output.append(name)
            if output.count >= limit { break }
        }
        return output
    }

    static func metadataLine(kind: MediaKind, genreIds: [Int]) -> String {
        let kindLabel = kind == .tv ? "TV Show" : "Movie"
        let genres = names(for: genreIds, kind: kind).joined(separator: " • ")
        if genres.isEmpty { return kindLabel }
        return "\(kindLabel) • \(genres)"
    }
}
