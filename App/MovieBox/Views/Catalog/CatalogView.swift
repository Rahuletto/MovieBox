import CoreMLEngine
import CoreMetadata
import CoreStorage
import DesignSystem
import MovieBoxCore
import SwiftData
import SwiftUI

struct CatalogView: View {
    @Environment(AppRouter.self) private var router
    @Query private var settings: [AppSettings]
    @Query private var ratings: [RatingRecord]
    @Query private var storedMovies: [MovieRecord]

    let kind: MediaKind

    @State private var rows: [MetadataCategory: [Movie]] = [:]
    @State private var extraSections: [HomeExtraSection] = []
    @State private var baseExtraSections: [HomeExtraSection] = []
    @State private var errorMessage: String?
    @State private var isCatalogRefreshing = false

    private var isCatalogContentVisible: Bool {
        rows.values.contains { !$0.isEmpty } || extraSections.contains { !$0.items.isEmpty }
    }

    var body: some View {
        ZStack {
            // Main content scroll view
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 36) {

                    if isCatalogRefreshing && !isCatalogContentVisible && errorMessage == nil {
                        ProgressView()
                            .controlSize(.regular)
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .padding(.top, 40)
                    } else if !isCatalogRefreshing && rows.values.allSatisfy(\.isEmpty) && extraSections.allSatisfy(\.items.isEmpty) {
                        ContentUnavailableView(
                            "Nothing here yet",
                            systemImage: kind == .movie ? "film" : "tv",
                            description: Text("Configure metadata access in Settings.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        if let trending = rows[.trending], !trending.isEmpty {
                            HeroCarousel(movies: Array(trending.prefix(5)), kind: kind) { movie in
                                router.showDetail(id: movie.id, kind: kind)
                            }
                            .frame(maxWidth: .infinity)
                        }

                        ForEach(MetadataCategory.allCases) { category in
                            if let items = rows[category], !items.isEmpty {
                                HorizontalMovieRow(title: category.displayTitle(for: kind), items: items) { movie in
                                    MoviePosterCard(
                                        title: movie.title,
                                        posterURL: MetadataClient().posterDisplayURL(
                                            posterPath: movie.posterPath,
                                            backdropPath: movie.backdropPath
                                        ),
                                            onHover: {
                                            if let mode = MetadataSettings.mode(from: settings) {
                                                Task { await Prefetcher.shared.prefetchDetail(id: movie.id, kind: kind, mode: mode) }
                                            }
                                        }
                                    ) {
                                        router.showDetail(id: movie.id, kind: kind)
                                    }
                                }
                            }
                        }

                        ForEach(extraSections, id: \.id) { section in
                            if !section.items.isEmpty {
                                HorizontalMovieRow(title: section.title, items: section.items) { movie in
                                    MoviePosterCard(
                                        title: movie.title,
                                        posterURL: MetadataClient().posterDisplayURL(
                                            posterPath: movie.posterPath,
                                            backdropPath: movie.backdropPath
                                        ),
                                        onHover: {
                                            if let mode = MetadataSettings.mode(from: settings) {
                                                Task { await Prefetcher.shared.prefetchDetail(id: movie.id, kind: kind, mode: mode) }
                                            }
                                        }
                                    ) {
                                        router.showDetail(id: movie.id, kind: kind)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 28)
            }
            .blur(radius: errorMessage != nil ? 18 : 0)

            // Fixed centered Error card floating on a blurred panel
            if let errorMessage {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()
                    
                    RetryCard(message: errorMessage) {
                        Task { await load() }
                    }
                    .frame(maxWidth: 420)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(settings.first?.cacheKey ?? "missing")|\(kind.rawValue)") {
            await load()
        }
        .task(id: personalizationKey) {
            await refreshPersonalizedSections()
        }
    }

    private var personalizationKey: String {
        let ratingPart = ratings
            .sorted { $0.tmdbId < $1.tmdbId }
            .map { "\($0.tmdbId):\($0.rating):\($0.ratedAt.timeIntervalSince1970)" }
            .joined(separator: "|")
        let watchPart = storedMovies
            .filter { $0.mediaKindEnum == kind }
            .sorted { $0.tmdbId < $1.tmdbId }
            .map {
                "\($0.tmdbId):\($0.watchedFraction):\($0.playbackPositionSeconds):\(($0.lastWatchedAt ?? .distantPast).timeIntervalSince1970):\(($0.watchlistAddedAt ?? .distantPast).timeIntervalSince1970)"
            }
            .joined(separator: "|")
        let rowPart = rows.values.flatMap { $0 }.map(\.id).sorted().map(String.init).joined(separator: ",")
        let basePart = baseExtraSections.flatMap(\.items).map(\.id).sorted().map(String.init).joined(separator: ",")
        return "\(ratingPart)#\(watchPart)#\(rowPart)#\(basePart)"
    }

    private func load() async {
        guard let mode = MetadataSettings.mode(from: settings) else {
            errorMessage = "Open Settings and configure metadata access first."
            return
        }
        isCatalogRefreshing = true
        errorMessage = nil
        rows = [:]
        baseExtraSections = []
        extraSections = []
        defer { isCatalogRefreshing = false }
        do {
            for try await payload in CatalogLoader.loadCatalogPayloadStream(mode: mode, kind: kind) {
                rows = payload.rows
                baseExtraSections = payload.extraSections
                await refreshPersonalizedSections()
            }
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }
            MetadataErrorLogger.record(error, context: "CatalogView load")
            errorMessage = MetadataErrorLogger.userMessage(
                for: error,
                backendURL: settings.first?.proxyBaseURL
            )
        }
    }

    private func refreshPersonalizedSections() async {
        extraSections = await withPersonalizedSection(
            baseSections: baseExtraSections,
            rows: rows
        )
    }

    private func withPersonalizedSection(
        baseSections: [HomeExtraSection],
        rows: [MetadataCategory: [Movie]]
    ) async -> [HomeExtraSection] {
        let explicitSignals = ratings.map {
            RatingSignal(
                tmdbId: $0.tmdbId,
                rating: $0.rating,
                genreIds: $0.genres,
                date: $0.ratedAt,
                source: .explicitRating
            )
        }

        let watchSignals = storedMovies
            .filter { $0.mediaKindEnum == kind && $0.lastWatchedAt != nil }
            .map { record in
                let signalStrength: Float
                if record.watchedFraction >= 0.8 {
                    signalStrength = 1.0
                } else if record.watchedFraction >= 0.2 {
                    signalStrength = 0.5
                } else if record.playbackPositionSeconds >= 30 {
                    signalStrength = -0.25
                } else {
                    signalStrength = 0
                }
                return RatingSignal(
                    tmdbId: record.tmdbId,
                    rating: signalStrength,
                    genreIds: record.genres,
                    date: record.lastWatchedAt ?? Date(),
                    source: .watchHistory
                )
            }

        let watchlistSignals = storedMovies
            .filter { $0.mediaKindEnum == kind && $0.watchlistAddedAt != nil }
            .map { record in
                RatingSignal(
                    tmdbId: record.tmdbId,
                    rating: 0.8,
                    genreIds: record.genres,
                    date: record.watchlistAddedAt ?? Date(),
                    source: .watchlist
                )
            }

        let signals = explicitSignals + watchSignals + watchlistSignals
        guard !signals.isEmpty else { return baseSections }

        var byMovieID: [Int: Movie] = [:]
        for movie in rows.values.flatMap({ $0 }) + baseSections.flatMap(\.items) {
            byMovieID[movie.id] = movie
        }
        let pool = Array(byMovieID.values)
        guard !pool.isEmpty else { return baseSections }

        let ratedOrWatchedIDs = Set(signals.map(\.tmdbId))
        let candidates = pool
            .filter { !ratedOrWatchedIDs.contains($0.id) }
            .map { movie in
                RecommendationCandidate(
                    id: movie.id,
                    genreIds: movie.genreIds,
                    baseScore: Float(movie.voteAverage / 10)
                )
            }
        guard !candidates.isEmpty else { return baseSections }

        let ranked = await GenreAffinityEngine().rank(candidates: candidates, ratings: signals)
        let personalized = ranked
            .compactMap { byMovieID[$0.id] }
            .prefix(20)
        guard !personalized.isEmpty else { return baseSections }

        let section = HomeExtraSection(
            id: kind == .movie ? "movie-because-you-watched" : "tv-because-you-watched",
            title: "Because You Watched",
            items: Array(personalized),
            kindByID: Dictionary(uniqueKeysWithValues: personalized.map { ($0.id, kind) })
        )

        return [section] + baseSections
    }
}
