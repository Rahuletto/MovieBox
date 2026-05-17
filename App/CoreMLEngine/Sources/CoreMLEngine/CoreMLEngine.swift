import Foundation

public struct RatingSignal: Sendable, Hashable {
    public let tmdbId: Int
    public let rating: Float
    public let genreIds: [Int]

    public init(tmdbId: Int, rating: Float, genreIds: [Int]) {
        self.tmdbId = tmdbId
        self.rating = rating
        self.genreIds = genreIds
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

    public func affinityVector(from ratings: [RatingSignal]) -> [Int: Float] {
        var vector: [Int: Float] = [:]
        var counts: [Int: Float] = [:]

        for rating in ratings {
            for genre in rating.genreIds {
                vector[genre, default: 0] += rating.rating
                counts[genre, default: 0] += 1
            }
        }

        for (genre, value) in vector {
            let average = value / max(counts[genre, default: 1], 1)
            vector[genre] = max(-1, min(1, average / 2))
        }

        return vector
    }

    public func rank(candidates: [RecommendationCandidate], ratings: [RatingSignal]) -> [RankedRecommendation] {
        let ratedIds = Set(ratings.map(\.tmdbId))
        let vector = affinityVector(from: ratings)

        return candidates
            .filter { !ratedIds.contains($0.id) }
            .map { candidate in
                let genreScore = candidate.genreIds.reduce(Float(0)) { partial, genre in
                    partial + vector[genre, default: 0]
                }
                let normalized = candidate.genreIds.isEmpty ? 0 : genreScore / Float(candidate.genreIds.count)
                return RankedRecommendation(id: candidate.id, score: normalized + candidate.baseScore)
            }
            .sorted { $0.score > $1.score }
    }
}

public enum RatingValue: Float, Sendable, CaseIterable {
    case dislike = -1
    case like = 1
    case doubleLike = 2
}
