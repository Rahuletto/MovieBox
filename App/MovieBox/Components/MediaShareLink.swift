import Foundation
import CoreMetadata

enum MediaShareLink {
    static func url(for detail: MovieDetail, kind: MediaKind) -> URL {
        if let imdbURL = imdbURL(from: detail.imdbId) {
            return imdbURL
        }
        let segment = kind == .movie ? "movie" : "tv"
        return URL(string: "https://www.themoviedb.org/\(segment)/\(detail.movie.id)")!
    }

    static func imdbURL(from imdbId: String?) -> URL? {
        guard let raw = imdbId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let id = raw.lowercased().hasPrefix("tt") ? raw : "tt\(raw)"
        return URL(string: "https://www.imdb.com/title/\(id)/")
    }
}
