import Combine
import CoreMLEngine
import CoreStorage
import CoreMetadata
import Foundation

/// Local ML training manager for recommendations
@MainActor
final class RecommendationTrainer: NSObject, ObservableObject {
    @Published var isTraining = false
    @Published var metrics: TrainingMetrics?
    @Published var error: String?
    
    private let engine = GenreAffinityEngine()
    
    struct TrainingMetrics: Sendable, Codable {
        let totalRatings: Int
        let avgRating: Float
        let genreDistribution: [Int: Int]
        let affinityVector: [Int: Float]
        let trainedAt: Date
        let modelVersion: String
        
        init(
            totalRatings: Int,
            avgRating: Float,
            genreDistribution: [Int: Int],
            affinityVector: [Int: Float],
            trainedAt: Date,
            modelVersion: String = "1.0"
        ) {
            self.totalRatings = totalRatings
            self.avgRating = avgRating
            self.genreDistribution = genreDistribution
            self.affinityVector = affinityVector
            self.trainedAt = trainedAt
            self.modelVersion = modelVersion
        }
    }
    
    /// Train model from stored ratings and watch history signals
    func train(ratings: [RatingRecord], storedMovies: [MovieRecord], candidates: [Movie]) async {
        isTraining = true
        error = nil

        // Convert ratings to signals
        let ratingSignals = ratings.map { rating in
            RatingSignal(
                tmdbId: rating.tmdbId,
                rating: rating.rating,
                genreIds: rating.genres,
                date: rating.ratedAt,
                source: .explicitRating
            )
        }

        // Watch history signals (implicit)
        let watchSignals = storedMovies.filter { $0.lastWatchedAt != nil }.map { movie in
            let ratingValue: Float
            if movie.watchedFraction >= 0.8 {
                ratingValue = 1.0
            } else if movie.watchedFraction >= 0.15 {
                ratingValue = 0.5
            } else if movie.playbackPositionSeconds >= 30 {
                ratingValue = -0.5
            } else {
                ratingValue = 0.0
            }
            return RatingSignal(
                tmdbId: movie.tmdbId,
                rating: ratingValue,
                genreIds: movie.genres,
                date: movie.lastWatchedAt ?? Date(),
                source: .watchHistory
            )
        }

        // Watchlist signals (implicit)
        let watchlistSignals = storedMovies.filter { $0.watchlistAddedAt != nil }.map { movie in
            RatingSignal(
                tmdbId: movie.tmdbId,
                rating: 1.0,
                genreIds: movie.genres,
                date: movie.watchlistAddedAt ?? Date(),
                source: .watchlist
            )
        }

        let signals = ratingSignals + watchSignals + watchlistSignals

        guard !signals.isEmpty else {
            error = "No signals available for training"
            isTraining = false
            return
        }

        // Compute affinity vector
        let affinity = await engine.affinityVector(from: signals)

        // Rank candidates
        let candidateRecords = candidates.map { movie in
            RecommendationCandidate(id: movie.id, genreIds: movie.genreIds, baseScore: Float(movie.voteAverage / 10))
        }
        _ = await engine.rank(candidates: candidateRecords, ratings: signals)

        // Compute metrics
        var genreDistribution: [Int: Int] = [:]
        for signal in signals {
            for genre in signal.genreIds {
                genreDistribution[genre, default: 0] += 1
            }
        }

        let avgRating = ratingSignals.isEmpty ? 0 : ratingSignals.map(\.rating).reduce(0, +) / Float(ratingSignals.count)

        metrics = TrainingMetrics(
            totalRatings: signals.count,
            avgRating: avgRating,
            genreDistribution: genreDistribution,
            affinityVector: affinity,
            trainedAt: Date()
        )

        // Cache results
        await cacheMetrics(metrics!)

        isTraining = false
    }
    
    private func cacheMetrics(_ metrics: TrainingMetrics) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        if let data = try? encoder.encode(metrics) {
            UserDefaults.standard.set(data, forKey: "ml_model_metrics")
        }
    }
    
    func loadCachedMetrics() {
        guard let data = UserDefaults.standard.data(forKey: "ml_model_metrics") else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        if let metrics = try? decoder.decode(TrainingMetrics.self, from: data) {
            self.metrics = metrics
        }
    }
}
