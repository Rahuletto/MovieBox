import Testing
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
