import Testing
import Foundation
@testable import CoreMLEngine

@Test func ranksUnratedMoviesByGenreAffinity() async {
    let engine = GenreAffinityEngine()
    let ratings = [
        RatingSignal(tmdbId: 1, rating: 2, genreIds: [28, 878]),
        RatingSignal(tmdbId: 2, rating: -1, genreIds: [27])
    ]
    let candidates = [
        RecommendationCandidate(id: 1, genreIds: [28]),
        RecommendationCandidate(id: 3, genreIds: [28, 878]),
        RecommendationCandidate(id: 4, genreIds: [27])
    ]

    let ranked = await engine.rank(candidates: candidates, ratings: ratings)

    #expect(ranked.map(\.id) == [3, 4])
    #expect((ranked.first?.score ?? 0) > (ranked.last?.score ?? 0))
}

@Test func handlesMultiSignalInputsAndDecay() async {
    let engine = GenreAffinityEngine()
    
    let now = Date()
    let twoWeeksAgo = now.addingTimeInterval(-14 * 86400)
    
    // User liked Action (28) 2 weeks ago (will decay)
    // User liked Sci-Fi (878) today (no decay)
    // User disliked Horror (27) today (strongly negative)
    // User watched Drama (18) partially today (positive)
    // User added Comedy (35) to watchlist today (watchlist multiplier: 0.5)
    let signals = [
        RatingSignal(tmdbId: 10, rating: 1.0, genreIds: [28], date: twoWeeksAgo, source: .explicitRating),
        RatingSignal(tmdbId: 11, rating: 1.0, genreIds: [878], date: now, source: .explicitRating),
        RatingSignal(tmdbId: 12, rating: -2.0, genreIds: [27], date: now, source: .explicitRating),
        RatingSignal(tmdbId: 13, rating: 0.5, genreIds: [18], date: now, source: .watchHistory),
        RatingSignal(tmdbId: 14, rating: 1.0, genreIds: [35], date: now, source: .watchlist)
    ]
    
    // Candidates:
    // Movie A: Sci-Fi (878) -> should rank highly (recent like)
    // Movie B: Action (28) -> should rank lower than Sci-Fi due to time decay
    // Movie C: Comedy (35) -> should rank moderate (watchlist weight 0.5)
    // Movie D: Horror (27) -> should rank lowest (explicit dislike)
    let candidates = [
        RecommendationCandidate(id: 101, genreIds: [878]),
        RecommendationCandidate(id: 102, genreIds: [28]),
        RecommendationCandidate(id: 103, genreIds: [35]),
        RecommendationCandidate(id: 104, genreIds: [27])
    ]
    
    let ranked = await engine.rank(candidates: candidates, ratings: signals)
    
    let rankedIds = ranked.map(\.id)
    #expect(rankedIds.first == 101) // Sci-Fi first
    #expect(rankedIds.contains(102)) // Action is in there
    #expect(rankedIds.contains(103)) // Comedy is in there
    #expect(rankedIds.last == 104) // Horror last
    
    // Check that Sci-Fi score is greater than Action score because of decay
    let sciFiScore = ranked.first(where: { $0.id == 101 })?.score ?? 0
    let actionScore = ranked.first(where: { $0.id == 102 })?.score ?? 0
    #expect(sciFiScore > actionScore)
}

@Test func filtersOutExplicitRatingsAndFullyWatched() async {
    let engine = GenreAffinityEngine()
    
    let signals = [
        RatingSignal(tmdbId: 1, rating: 1.0, genreIds: [28], source: .explicitRating),
        RatingSignal(tmdbId: 2, rating: 1.0, genreIds: [28], source: .watchHistory), // watchedFraction = 1.0 (fully watched)
        RatingSignal(tmdbId: 3, rating: 0.4, genreIds: [28], source: .watchHistory), // watchedFraction = 0.4 (partially watched)
        RatingSignal(tmdbId: 4, rating: 1.0, genreIds: [28], source: .watchlist)
    ]
    
    let candidates = [
        RecommendationCandidate(id: 1, genreIds: [28]), // Explicitly rated -> Excluded
        RecommendationCandidate(id: 2, genreIds: [28]), // Fully watched -> Excluded
        RecommendationCandidate(id: 3, genreIds: [28]), // Partially watched -> Included
        RecommendationCandidate(id: 4, genreIds: [28])  // Watchlisted only -> Included
    ]
    
    let ranked = await engine.rank(candidates: candidates, ratings: signals)
    let rankedIds = ranked.map(\.id)
    
    #expect(!rankedIds.contains(1))
    #expect(!rankedIds.contains(2))
    #expect(rankedIds.contains(3))
    #expect(rankedIds.contains(4))
}

@Test func testOfflineEvaluationMetrics() async {
    let engine = GenreAffinityEngine()
    
    // 1. User profile: User likes Action (28) and Sci-Fi (878), and dislikes Horror (27)
    // 2. Training Signals: Historical signals the recommender learns from
    let trainingSignals = [
        RatingSignal(tmdbId: 10, rating: 2.0, genreIds: [28, 878]),
        RatingSignal(tmdbId: 11, rating: 1.0, genreIds: [28]),
        RatingSignal(tmdbId: 12, rating: -2.0, genreIds: [27]),
        RatingSignal(tmdbId: 13, rating: 1.0, genreIds: [878])
    ]
    
    // 3. Ground Truth: Unrated movies in the hold-out test set that the user actually liked
    let groundTruthLikes = Set([201, 202])
    
    // 4. Candidates list
    let candidates = [
        RecommendationCandidate(id: 201, genreIds: [28, 878], baseScore: 0.8), // Strong Match (Action + Sci-Fi)
        RecommendationCandidate(id: 202, genreIds: [28], baseScore: 0.7),      // Medium Match (Action)
        RecommendationCandidate(id: 203, genreIds: [27], baseScore: 0.9),      // Disliked Genre (Horror)
        RecommendationCandidate(id: 204, genreIds: [35], baseScore: 0.6)       // Neutral Genre (Comedy)
    ]
    
    let ranked = await engine.rank(candidates: candidates, ratings: trainingSignals)
    
    // Evaluate Top-K (K=2) recommendations
    let k = 2
    let recommendations = Array(ranked.prefix(k)).map(\.id)
    
    let relevantRecommendations = recommendations.filter { groundTruthLikes.contains($0) }
    
    let precision = Float(relevantRecommendations.count) / Float(k)
    let recall = Float(relevantRecommendations.count) / Float(groundTruthLikes.count)
    
    print("--- Hold-out Simulation Evaluation ---")
    print("Top \(k) Recommendations: \(recommendations)")
    print("Precision@\(k): \(precision * 100)%")
    print("Recall@\(k): \(recall * 100)%")
    
    #expect(precision == 1.0)
    #expect(recall == 1.0)
}
