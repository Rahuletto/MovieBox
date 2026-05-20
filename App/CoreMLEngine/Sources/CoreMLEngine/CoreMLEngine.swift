import Foundation

public struct RatingSignal: Sendable, Hashable {
    public let tmdbId: Int
    public let rating: Float
    public let genreIds: [Int]
    public let date: Date
    public let source: SignalSource

    public enum SignalSource: String, Sendable, Codable {
        case explicitRating
        case watchHistory
        case watchlist
    }

    public init(
        tmdbId: Int,
        rating: Float,
        genreIds: [Int],
        date: Date = Date(),
        source: SignalSource = .explicitRating
    ) {
        self.tmdbId = tmdbId
        self.rating = rating
        self.genreIds = genreIds
        self.date = date
        self.source = source
    }
}

public struct RecommendationCandidate: Sendable, Hashable, Identifiable {
    public let id: Int
    public let genreIds: [Int]
    public let baseScore: Float

    public init(id: Int, genreIds: [Int], baseScore: Float = 0) {
        self.id = id
        self.genreIds = genreIds
        self.baseScore = baseScore
    }
}

public struct RankedRecommendation: Sendable, Hashable, Identifiable {
    public let id: Int
    public let score: Float

    public init(id: Int, score: Float) {
        self.id = id
        self.score = score
    }
}

public actor GenreAffinityEngine {
    public init() {}

    private func tanh(_ x: Float) -> Float {
        let doubleX = Double(x)
        return Float(Foundation.tanh(doubleX))
    }

    private func exp(_ x: Float) -> Float {
        return Float(Foundation.exp(Double(x)))
    }

    private func sqrt(_ x: Float) -> Float {
        return Float(Foundation.sqrt(Double(x)))
    }

    public func affinityVector(from ratings: [RatingSignal]) -> [Int: Float] {
        return affinityVector(from: ratings, decayLambda: 0.05)
    }

    public func affinityVector(from signals: [RatingSignal], decayLambda: Float) -> [Int: Float] {
        var genreScores: [Int: Float] = [:]
        let now = Date()

        for signal in signals {
            let elapsedSeconds = now.timeIntervalSince(signal.date)
            let elapsedDays = Float(max(0.0, elapsedSeconds / 86400.0))
            let decay = exp(-decayLambda * elapsedDays)
            
            let sourceWeightMultiplier: Float
            switch signal.source {
            case .explicitRating:
                sourceWeightMultiplier = 1.0
            case .watchHistory:
                sourceWeightMultiplier = 1.0
            case .watchlist:
                sourceWeightMultiplier = 0.5
            }

            let signalScore = signal.rating * sourceWeightMultiplier * decay

            for genre in signal.genreIds {
                genreScores[genre, default: 0] += signalScore
            }
        }

        var normalizedVector: [Int: Float] = [:]
        for (genre, score) in genreScores {
            normalizedVector[genre] = tanh(score)
        }

        return normalizedVector
    }

    public func rank(candidates: [RecommendationCandidate], ratings: [RatingSignal]) -> [RankedRecommendation] {
        return rank(candidates: candidates, ratings: ratings, decayLambda: 0.05)
    }

    public func rank(
        candidates: [RecommendationCandidate],
        ratings: [RatingSignal],
        decayLambda: Float = 0.05
    ) -> [RankedRecommendation] {
        var excludedIds = Set<Int>()
        for signal in ratings {
            if signal.source == .explicitRating {
                excludedIds.insert(signal.tmdbId)
            } else if signal.source == .watchHistory && signal.rating >= 0.8 {
                excludedIds.insert(signal.tmdbId)
            }
        }

        let vector = affinityVector(from: ratings, decayLambda: decayLambda)

        return candidates
            .filter { !excludedIds.contains($0.id) }
            .map { candidate in
                let genreScore = candidate.genreIds.reduce(Float(0)) { partial, genre in
                    partial + vector[genre, default: 0]
                }
                let norm = max(1.0, sqrt(Float(candidate.genreIds.count)))
                let normalizedScore = genreScore / norm
                
                let finalScore = (normalizedScore * 0.8) + (candidate.baseScore * 0.2)
                
                return RankedRecommendation(id: candidate.id, score: finalScore)
            }
            .sorted { $0.score > $1.score }
    }
}

public enum RatingValue: Float, Sendable, CaseIterable {
    case dislike = -1
    case like = 1
    case doubleLike = 2
}
