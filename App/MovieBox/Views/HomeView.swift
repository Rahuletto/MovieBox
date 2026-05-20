import CoreMLEngine
import CoreMetadata
import CoreStorage
import DesignSystem
import MovieBoxCore
import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Query private var settings: [AppSettings]
    @Query private var ratings: [RatingRecord]
    @Query private var storedMovies: [MovieRecord]
    @Query(sort: \DownloadRecord.createdAt, order: .reverse) private var downloads: [DownloadRecord]
    @State private var rows: [MetadataCategory: [Movie]] = [:]
    @State private var kindByID: [Int: MediaKind] = [:]
    @State private var extraSections: [HomeExtraSection] = []
    @State private var recommended: [Movie] = []
    @State private var continueWatching: [MovieRecord] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        ZStack {
            // Ambient subtle background gradient for an elite glow
            RadialGradient(
                colors: [Color.red.opacity(0.12), Color.clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 480
            )
            .ignoresSafeArea()
            


            if metadataMode == nil {
                ContentUnavailableView(
                    "Metadata Not Configured",
                    systemImage: "key",
                    description: Text("Open Settings and add either a backend URL with app token or a TMDB bearer token.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    ZStack(alignment: .top) {
                        LazyVStack(alignment: .leading, spacing: 42) {
                                 if let trending = rows[.trending], !trending.isEmpty {
                                      HeroCarousel(
                                          movies: Array(trending.prefix(8)),
                                          kind: .movie,
                                          kindForMovie: { movie in
                                              kindByID[movie.id] ?? .movie
                                          }
                                      ) { movie in
                                          router.showDetail(id: movie.id, kind: kindByID[movie.id] ?? .movie)
                                      }
                                      .frame(maxWidth: .infinity)
                                  }

                            if !continueWatching.isEmpty {
                                ContinueWatchingRow(records: continueWatching) { record in
                                    router.showDetail(id: record.tmdbId, kind: record.mediaKindEnum)
                                }
                            }

                            if !watchlistItems.isEmpty {
                                HomeQuickAccessRow(
                                    title: "Your Watchlist",
                                    items: watchlistItems
                                ) { item in
                                    router.showDetail(id: item.tmdbId, kind: item.kind)
                                }
                            }

                            if !downloadItems.isEmpty {
                                HomeQuickAccessRow(
                                    title: "Downloads",
                                    items: downloadItems
                                ) { item in
                                    if item.tmdbId > 0 {
                                        router.showDetail(id: item.tmdbId, kind: item.kind)
                                    } else {
                                        router.show(.downloads)
                                    }
                                }
                            }

                            if !recommended.isEmpty {
                                HorizontalMovieRow(title: "Recommended For You", items: recommended) { movie in
                                    MoviePosterCard(
                                        title: movie.title,
                                        subtitle: movie.releaseDate,
                                        posterURL: posterURL(for: movie)
                                    ) {
                                        router.showDetail(id: movie.id, kind: kindByID[movie.id] ?? .movie)
                                    }
                                }
                            }

                            if isLoading && rows.isEmpty {
                                ProgressView("Loading movies...")
                                    .controlSize(.large)
                                    .frame(maxWidth: .infinity, minHeight: 260)
                            }

                            ForEach(MetadataCategory.allCases) { category in
                                if let movies = rows[category], !movies.isEmpty {
                                    HorizontalMovieRow(title: category.rawValue, items: movies) { movie in
                                        MoviePosterCard(
                                            title: movie.title,
                                            subtitle: movie.releaseDate,
                                            posterURL: posterURL(for: movie)
                                        ) {
                                            router.showDetail(id: movie.id, kind: kindByID[movie.id] ?? .movie)
                                        }
                                    }
                                }
                            }

                            ForEach(extraSections, id: \.id) { section in
                                if !section.items.isEmpty {
                                    HorizontalMovieRow(title: section.title, items: section.items) { movie in
                                        MoviePosterCard(
                                            title: movie.title,
                                            subtitle: movie.releaseDate,
                                            posterURL: posterURL(for: movie)
                                        ) {
                                            router.showDetail(
                                                id: movie.id,
                                                kind: section.kindByID[movie.id] ?? .movie
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 28)
                        
                        // Scroll offset tracker (invisible)
                        GeometryReader { geo in
                            Color.clear.preference(key: ScrollOffsetPreferenceKey.self, value: geo.frame(in: .named("scroll")).minY)
                        }
                        .frame(height: 0)
                    }
                }
                .coordinateSpace(name: "scroll")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                    scrollOffset = offset
                }
                .scrollIndicators(.hidden)
                .blur(radius: errorMessage != nil ? 18 : 0)
                .opacity(rows.isEmpty ? 0 : 1)
            }
            
            // Full screen loading (if rows is empty)
            if isLoading && rows.isEmpty && metadataMode != nil {
                ProgressView("Loading movies...")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Fixed centered Error card floating on a blurred panel
            if let errorMessage {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()
                    
                    if let mode = metadataMode {
                        RetryCard(message: errorMessage) {
                            Task { await load(mode: mode) }
                        }
                        .frame(maxWidth: 420)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else {
                        RetryCard(message: errorMessage) {
                            if let mode = metadataMode {
                                Task { await load(mode: mode) }
                            }
                        }
                        .frame(maxWidth: 420)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: settingsKey) {
            guard metadataMode != nil else { return }
            guard let mode = await MetadataSettings.resolveMode(from: settings) else { return }
            await load(mode: mode)
        }
        .task(id: personalizationKey) {
            await refreshRecommendations()
        }
    }

    private var metadataMode: MetadataEndpointMode? {
        MetadataSettings.mode(from: settings)
    }

    private var settingsKey: String {
        guard let setting = settings.first else { return "missing" }
        return "\(setting.proxyBaseURL)|\(setting.tmdbBearerToken)|\(setting.posterSize)|\(setting.backdropSize)|\(setting.requestTimeout)"
    }

    private var personalizationKey: String {
        let ratingPart = ratings
            .sorted { $0.tmdbId < $1.tmdbId }
            .map { "\($0.tmdbId):\($0.rating):\($0.ratedAt.timeIntervalSince1970)" }
            .joined(separator: "|")
        let watchPart = storedMovies
            .sorted { $0.tmdbId < $1.tmdbId }
            .map {
                "\($0.tmdbId):\($0.watchedFraction):\($0.playbackPositionSeconds):\(($0.lastWatchedAt ?? .distantPast).timeIntervalSince1970):\(($0.watchlistAddedAt ?? .distantPast).timeIntervalSince1970)"
            }
            .joined(separator: "|")
        let rowPart = rows.values.flatMap { $0 }.map(\.id).sorted().map(String.init).joined(separator: ",")
        return "\(ratingPart)#\(watchPart)#\(rowPart)"
    }

    private func load(mode: MetadataEndpointMode) async {
        isLoading = true
        errorMessage = nil
        do {
            let payload = try await CatalogLoader.loadHomePayload(mode: mode)
            rows = payload.rows
            kindByID = payload.kindsByID
            extraSections = payload.extraSections
            await refreshRecommendations()

            continueWatching = storedMovies
                .filter {
                    PlaybackDisplayTitle.hasContinueProgress(
                        positionSeconds: $0.playbackPositionSeconds,
                        watchedFraction: $0.watchedFraction
                    )
                }
                .sorted { ($0.lastWatchedAt ?? .distantPast) > ($1.lastWatchedAt ?? .distantPast) }
                .prefix(8)
                .map { $0 }
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }
            MetadataErrorLogger.record(error, context: "Home catalog load")
            errorMessage = MetadataErrorLogger.userMessage(
                for: error,
                backendURL: settings.first?.proxyBaseURL
            )
        }
        isLoading = false
    }

    private func refreshRecommendations() async {
        let trending = rows[.trending] ?? []
        let popular = rows[.popular] ?? []
        let topRated = rows[.topRated] ?? []

        var uniqueMoviesMap: [Int: Movie] = [:]
        for movie in (trending + popular + topRated) {
            uniqueMoviesMap[movie.id] = movie
        }
        let allMovies = Array(uniqueMoviesMap.values)
        guard !allMovies.isEmpty else {
            recommended = []
            return
        }

        let ratingSignals = ratings.map { rating in
            RatingSignal(
                tmdbId: rating.tmdbId,
                rating: rating.rating,
                genreIds: rating.genres,
                date: rating.ratedAt,
                source: .explicitRating
            )
        }

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

        let watchlistSignals = storedMovies.filter { $0.watchlistAddedAt != nil }.map { movie in
            RatingSignal(
                tmdbId: movie.tmdbId,
                rating: 1.0,
                genreIds: movie.genres,
                date: movie.watchlistAddedAt ?? Date(),
                source: .watchlist
            )
        }

        let allSignals = ratingSignals + watchSignals + watchlistSignals
        guard !allSignals.isEmpty else {
            recommended = []
            return
        }

        let engine = GenreAffinityEngine()
        let candidates = allMovies.map {
            RecommendationCandidate(id: $0.id, genreIds: $0.genreIds, baseScore: Float($0.voteAverage / 10))
        }
        let ranked = await engine.rank(candidates: candidates, ratings: allSignals)
        recommended = ranked.compactMap { uniqueMoviesMap[$0.id] }.prefix(12).map { $0 }
    }

    private var watchlistItems: [HomeQuickAccessItem] {
        storedMovies
            .filter { $0.watchlistAddedAt != nil }
            .sorted { ($0.watchlistAddedAt ?? .distantPast) > ($1.watchlistAddedAt ?? .distantPast) }
            .prefix(12)
            .map {
                HomeQuickAccessItem(
                    id: "watch-\($0.tmdbId)",
                    tmdbId: $0.tmdbId,
                    kind: $0.mediaKindEnum,
                    title: $0.title,
                    subtitle: $0.mediaKindEnum == .tv ? "Show" : "Movie",
                    posterURL: MetadataClient().imageURL(path: $0.posterPath)
                )
            }
    }

    private var downloadItems: [HomeQuickAccessItem] {
        downloads
            .prefix(12)
            .map { download in
                let matchingRecord = storedMovies.first(where: { $0.tmdbId == download.tmdbId && $0.mediaKind == download.mediaKind })
                return HomeQuickAccessItem(
                    id: "dl-\(download.infoHash)",
                    tmdbId: download.tmdbId,
                    kind: download.mediaKindEnum,
                    title: download.title,
                    subtitle: "Download",
                    posterURL: MetadataClient().imageURL(path: matchingRecord?.posterPath)
                )
            }
    }

    private func posterURL(for movie: Movie) -> URL? {
        let client = MetadataClient()
        if let poster = client.imageURL(path: movie.posterPath) {
            return poster
        }
        return client.imageURL(path: movie.backdropPath)
    }
}

private struct HomeQuickAccessItem: Identifiable {
    let id: String
    let tmdbId: Int
    let kind: MediaKind
    let title: String
    let subtitle: String
    let posterURL: URL?
}

private struct HomeQuickAccessRow: View {
    let title: String
    let items: [HomeQuickAccessItem]
    let onSelect: (HomeQuickAccessItem) -> Void

    var body: some View {
        HorizontalMovieRow(title: title, items: items) { item in
            MoviePosterCard(
                title: item.title,
                subtitle: item.subtitle,
                posterURL: item.posterURL
            ) {
                onSelect(item)
            }
        }
    }
}

private struct ContinueWatchingRow: View {
    @Environment(AppRouter.self) private var router
    @State private var movieDetails: [Int: Movie] = [:]
    let records: [MovieRecord]
    let action: (MovieRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue Watching")
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(records, id: \.tmdbId) { record in
                        Button {
                            action(record)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                continueWatchingBanner(for: record)

                                Text(record.title)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                    .frame(width: 360, alignment: .leading)

                                if let remaining = WatchProgressStore.timeRemainingLabel(for: record) {
                                    Text(remaining)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 360, alignment: .leading)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .task {
                            await fetchMovieDetail(for: record)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    @ViewBuilder
    private func continueWatchingBanner(for record: MovieRecord) -> some View {
        let progress = WatchProgressStore.progressFraction(for: record)
        let backdropPath = movieDetails[record.tmdbId]?.backdropPath ?? record.posterPath

        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .frame(width: 360, height: 200)
            .overlay {
                CachedImageView(url: MetadataClient().imageURL(path: backdropPath)) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                } content: { image in
                    image.resizable().scaledToFill()
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 56)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.white.opacity(0.25))
                            Capsule()
                                .fill(.white)
                                .frame(width: max(4, geo.size.width * progress))
                        }
                    }
                    .frame(height: 4)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func fetchMovieDetail(for record: MovieRecord) async {
        guard movieDetails[record.tmdbId] == nil else { return }
        do {
            let client = MetadataClient()
            let detail = try await client.movieDetail(id: record.tmdbId, kind: record.mediaKindEnum)
            movieDetails[record.tmdbId] = detail.movie
        } catch {
            print("Failed to fetch movie detail for \(record.tmdbId): \(error)")
        }
    }
}
