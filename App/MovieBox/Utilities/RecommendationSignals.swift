import CoreMLEngine
import CoreMetadata
import CoreStorage
import Foundation
import MovieBoxCore

enum RecommendationSignals {
    static func build(
        ratings: [RatingRecord],
        storedMovies: [MovieRecord],
        kind: MediaKind? = nil,
        watchlistSignalStrength: Float = 1.0
    ) -> [RatingSignal] {
        let explicitSignals = ratings.map {
            RatingSignal(
                tmdbId: $0.tmdbId,
                rating: $0.rating,
                genreIds: $0.genres,
                date: $0.ratedAt,
                source: .explicitRating
            )
        }

        let filteredMovies = storedMovies.filter {
            guard let kind else { return true }
            return $0.mediaKindEnum == kind
        }

        let watchSignals = filteredMovies
            .filter { $0.lastWatchedAt != nil }
            .map { record in
                RatingSignal(
                    tmdbId: record.tmdbId,
                    rating: watchHistorySignalStrength(for: record),
                    genreIds: record.genres,
                    date: record.lastWatchedAt ?? Date(),
                    source: .watchHistory
                )
            }

        let watchlistSignals = filteredMovies
            .filter { $0.watchlistAddedAt != nil }
            .map { record in
                RatingSignal(
                    tmdbId: record.tmdbId,
                    rating: watchlistSignalStrength,
                    genreIds: record.genres,
                    date: record.watchlistAddedAt ?? Date(),
                    source: .watchlist
                )
            }

        return explicitSignals + watchSignals + watchlistSignals
    }

    static func watchHistorySignalStrength(for record: MovieRecord) -> Float {
        if record.watchedFraction >= 0.8 {
            return 1.0
        } else if record.watchedFraction >= 0.2 {
            return 0.5
        } else if record.playbackPositionSeconds >= 30 {
            return -0.25
        }
        return 0
    }
}
