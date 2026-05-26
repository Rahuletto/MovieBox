import CoreMetadata
import CoreStorage
import MovieBoxCore
import SwiftData
import SwiftUI

extension MovieDetailView {
    func addToMyList(_ movie: Movie) {
        if let existing = storedMovies.first(where: { $0.tmdbId == movie.id }) {
            if existing.watchlistAddedAt != nil {
                existing.watchlistAddedAt = nil
            } else {
                existing.watchlistAddedAt = Date()
                if existing.title.isEmpty { existing.title = movie.title }
                if existing.posterPath == nil { existing.posterPath = movie.posterPath }
                if existing.genres.isEmpty { existing.genres = movie.genreIds }
            }
            try? modelContext.save()
            return
        }

        let record = MovieRecord(
            tmdbId: movie.id,
            mediaKind: kind.storageValue,
            title: movie.title,
            posterPath: movie.posterPath,
            genres: movie.genreIds,
            watchlistAddedAt: Date()
        )
        modelContext.insert(record)
        try? modelContext.save()
    }

    func rateMovie(_ rating: Float) {
        if let existing = ratings.first(where: { $0.tmdbId == movieId }) {
            if rating == 0 {
                modelContext.delete(existing)
            } else {
                existing.rating = rating
                existing.ratedAt = Date()
            }
        } else if rating > 0 {
            let record = RatingRecord(
                tmdbId: movieId,
                rating: rating,
                genres: detail?.movie.genreIds ?? []
            )
            modelContext.insert(record)
        }
        try? modelContext.save()
    }
}
