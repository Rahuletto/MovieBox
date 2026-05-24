import CoreMLEngine
import CoreMetadata
import CorePlayer
import CoreStorage
import DesignSystem
import MovieBoxCore
import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PlayerState.self) private var playerState
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
    @State private var scrollOffset: CGFloat = 0
    @State private var isHomeRefreshing = false

    private var isHomeCatalogVisible: Bool {
        MetadataCategory.allCases.contains { !(rows[$0]?.isEmpty ?? true) }
            || extraSections.contains { !$0.items.isEmpty }
    }

    /// Local library rows come from SwiftData immediately; hide them until catalog shelves are ready
    /// so launch does not flash "Your Watchlist" alone while metadata loads.
    private var showsPersonalSections: Bool {
        isHomeCatalogVisible || (!isHomeRefreshing && errorMessage != nil)
    }

    var body: some View {
        ZStack {
            AmbientTopGlow(color: MovieBoxColors.homeGlow)


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
                            if isHomeRefreshing && !isHomeCatalogVisible && errorMessage == nil {
                                HomeCatalogLoadingView()
                            } else {
                                if let trending = rows[.trending], !trending.isEmpty {
                                    HeroCarousel(
                                        movies: Array(trending.prefix(8)),
                                        kind: .movie,
                                        isActive: allowsMetadataFetch,
                                        kindForMovie: { movie in
                                            kindByID[movie.id] ?? .movie
                                        }
                                    ) { movie in
                                        router.showDetail(id: movie.id, kind: kindByID[movie.id] ?? .movie)
                                    }
                                    .frame(maxWidth: .infinity)
                                }

                                if showsPersonalSections {
                                    if !continueWatching.isEmpty {
                                        ContinueWatchingRow(
                                            records: continueWatching,
                                            metadataMode: metadataMode
                                        ) { record in
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
                                }

                                if !recommended.isEmpty {
                                    HorizontalMovieRow(title: "Recommended For You", items: recommended) { movie in
                                        MoviePosterCard(
                                            title: movie.title,
                                            posterURL: posterURL(for: movie)
                                        ) {
                                            router.showDetail(id: movie.id, kind: kindByID[movie.id] ?? .movie)
                                        }
                                    }
                                }

                                ForEach(MetadataCategory.allCases) { category in
                                    if let movies = rows[category], !movies.isEmpty {
                                        HorizontalMovieRow(title: category.rawValue, items: movies) { movie in
                                            MoviePosterCard(
                                                title: movie.title,
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
                        }
                        .padding(.bottom, 28)
                        .animation(MovieBoxMotion.chrome, value: isHomeCatalogVisible)
                        
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
        .task(id: catalogTaskKey) {
            guard allowsMetadataFetch, metadataMode != nil else { return }
            guard let mode = metadataMode else { return }
            await load(mode: mode)
        }
        .task(id: personalizationKey) {
            guard allowsMetadataFetch else { return }
            await refreshRecommendations()
        }
    }

    private var allowsMetadataFetch: Bool {
        BackgroundFetchGate.allowsMetadataNetworking(
            router: router,
            playerState: playerState,
            tab: .home
        )
    }

    private var catalogTaskKey: String {
        "\(settingsKey)|fetch:\(allowsMetadataFetch)"
    }

    private var metadataMode: MetadataEndpointMode? {
        MetadataSettings.mode(from: settings)
    }

    private var settingsKey: String {
        guard let setting = settings.first else { return "missing" }
        return "\(setting.useLocalBackend)|\(setting.resolvedProxyBaseURL)|\(setting.tmdbBearerToken)|\(setting.posterSize)|\(setting.backdropSize)|\(setting.requestTimeout)"
    }

    private var personalizationKey: String {
        let ratingPart = ratings
            .sorted { $0.tmdbId < $1.tmdbId }
            .map { "\($0.tmdbId):\($0.rating):\($0.ratedAt.timeIntervalSince1970)" }
            .joined(separator: "|")
        let watchlistPart = storedMovies
            .filter { $0.watchlistAddedAt != nil }
            .sorted { $0.tmdbId < $1.tmdbId }
            .map { String($0.tmdbId) }
            .joined(separator: ",")
        let completedPart = storedMovies
            .filter { $0.watchedFraction >= 0.8 }
            .sorted { $0.tmdbId < $1.tmdbId }
            .map { String($0.tmdbId) }
            .joined(separator: ",")
        return "\(ratingPart)#wl:\(watchlistPart)#done:\(completedPart)"
    }

    private func load(mode: MetadataEndpointMode) async {
        errorMessage = nil
        if !isHomeCatalogVisible {
            isHomeRefreshing = true
        }
        defer { isHomeRefreshing = false }

        do {
            var sawCorePayload = false
            for try await payload in CatalogLoader.loadHomePayloadStream(mode: mode) {
                rows = payload.rows
                kindByID = payload.kindsByID
                extraSections = payload.extraSections
                if !sawCorePayload {
                    sawCorePayload = true
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
                    await refreshRecommendations()
                } else {
                    await refreshRecommendations()
                }
            }
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }
            MetadataErrorLogger.record(error, context: "Home catalog load")
            errorMessage = MetadataErrorLogger.userMessage(
                for: error,
                backendURL: settings.first?.resolvedProxyBaseURL
            )
        }
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
        MetadataClient().posterDisplayURL(posterPath: movie.posterPath, backdropPath: movie.backdropPath)
    }
}

private struct HomeCatalogLoadingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 42) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(maxWidth: .infinity)
                .frame(height: 420)
                .padding(.horizontal, 20)
                .redacted(reason: .placeholder)

            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 140, height: 18)
                    .padding(.horizontal, 20)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                                .frame(width: MoviePosterCard.posterWidth, height: MoviePosterCard.posterHeight)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .redacted(reason: .placeholder)

            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading home")
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
    let metadataMode: MetadataEndpointMode?
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
                                    .font(.body.weight(.semibold))
                                    .lineLimit(1)
                                    .frame(width: 360, alignment: .leading)

                                if let remaining = WatchProgressStore.timeRemainingLabel(for: record) {
                                    Text(remaining)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 360, alignment: .leading)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .task {
            await prefetchMovieDetails()
        }
    }

    @ViewBuilder
    private func continueWatchingBanner(for record: MovieRecord) -> some View {
        let progress = WatchProgressStore.progressFraction(for: record)
        let movie = movieDetails[record.tmdbId]
        let bannerPath = movie?.backdropPath ?? movie?.posterPath ?? record.posterPath
        let imageURL = bannerPath.flatMap { MetadataClient().imageURL(path: $0, width: 780) }

        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .frame(width: 360, height: 200)
            .overlay {
                if let imageURL {
                    CachedImageView(url: imageURL) {
                        ProgressView()
                    } content: { image in
                        image.resizable().scaledToFill()
                    }
                    .id(imageURL)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Image(systemName: "film.stack")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.35))
                        Capsule()
                            .fill(.white)
                            .frame(width: max(4, geo.size.width * progress))
                    }
                }
                .frame(height: 4)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func prefetchMovieDetails() async {
        await withTaskGroup(of: Void.self) { group in
            for record in records {
                guard movieDetails[record.tmdbId] == nil else { continue }
                group.addTask {
                    await fetchMovieDetail(for: record)
                }
            }
        }
    }

    private func fetchMovieDetail(for record: MovieRecord) async {
        guard movieDetails[record.tmdbId] == nil else { return }
        guard let mode = metadataMode else { return }
        do {
            let client = MetadataClient(mode: mode)
            let detail = try await client.movieDetail(id: record.tmdbId, kind: record.mediaKindEnum)
            await MainActor.run {
                movieDetails[record.tmdbId] = detail.movie
            }
        } catch {
            NSLog("Continue Watching backdrop fetch failed for \(record.tmdbId): \(error.localizedDescription)")
        }
    }
}
