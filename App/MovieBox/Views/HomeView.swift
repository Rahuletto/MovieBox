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
    @Query private var storedMovies: [MovieRecord]
    @State private var rows: [MetadataCategory: [Movie]] = [:]
    @State private var kindByID: [Int: MediaKind] = [:]
    @State private var extraSections: [HomeExtraSection] = []
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
            AmbientPageGlow(color: MovieBoxColors.homeGlow)


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

                                }

                                if isHomeCatalogVisible {
                                    homePosterShelf(
                                        title: MetadataCategory.trending.rawValue,
                                        movies: rows[.trending],
                                        shelfKey: "trending"
                                    )

                                    homePosterShelf(
                                        title: MetadataCategory.popular.rawValue,
                                        movies: rows[.popular],
                                        shelfKey: "popular"
                                    )

                                    if let nowPlaying = rows[.nowPlaying], nowPlaying.count >= 2 {
                                        FeaturedLandscapeRow(
                                            title: MetadataCategory.nowPlaying.rawValue,
                                            movies: Array(nowPlaying.prefix(10)),
                                            kindForMovie: { kindByID[$0.id] ?? .movie }
                                        ) { movie in
                                            router.showDetail(
                                                id: movie.id,
                                                kind: kindByID[movie.id] ?? .movie
                                            )
                                        }
                                    }

                                    if let topRated = rows[.topRated], topRated.count >= 3 {
                                        FeaturedSpotlightRow(
                                            title: "Must See",
                                            movies: Array(topRated.prefix(10)),
                                            kindForMovie: { kindByID[$0.id] ?? .movie }
                                        ) { movie in
                                            router.showDetail(
                                                id: movie.id,
                                                kind: kindByID[movie.id] ?? .movie
                                            )
                                        }
                                    }

                                    homeExtraPosterShelf(id: "critically-acclaimed")

                                    homePosterShelf(
                                        title: MetadataCategory.topRated.rawValue,
                                        movies: rows[.topRated],
                                        shelfKey: "top-rated"
                                    )

                                    homeExtraPosterShelf(id: "binge-worthy-shows")
                                    homeExtraPosterShelf(id: "oscar-winners")

                                    ExploreGenresSection()
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

    private func posterURL(for movie: Movie) -> URL? {
        MetadataClient().posterDisplayURL(posterPath: movie.posterPath, backdropPath: movie.backdropPath)
    }

    private func extraSection(id: String) -> HomeExtraSection? {
        extraSections.first { $0.id == id }
    }

    @ViewBuilder
    private func homePosterShelf(title: String, movies: [Movie]?, shelfKey: String) -> some View {
        if let movies, !movies.isEmpty {
            HorizontalMovieRow(
                title: title,
                items: movies,
                itemIdentity: { "home-\(shelfKey)-\($0.id)" }
            ) { movie in
                MoviePosterCard(
                    title: movie.title,
                    posterURL: posterURL(for: movie)
                ) {
                    router.showDetail(
                        id: movie.id,
                        kind: kindByID[movie.id] ?? .movie
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func homeExtraPosterShelf(id: String) -> some View {
        if let section = extraSection(id: id), !section.items.isEmpty {
            HorizontalMovieRow(
                title: section.title,
                items: section.items,
                itemIdentity: { "home-\(id)-\($0.id)" }
            ) { movie in
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

private struct HomeCatalogLoadingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 42) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(maxWidth: .infinity)
                .frame(height: 420)
                .padding(.horizontal, MovieBoxLayout.shelfHorizontalInset)
                .redacted(reason: .placeholder)

            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 140, height: 18)
                    .padding(.horizontal, MovieBoxLayout.shelfHorizontalInset)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                                .frame(width: MoviePosterCard.posterWidth, height: MoviePosterCard.posterHeight)
                        }
                    }
                    .padding(.horizontal, MovieBoxLayout.shelfHorizontalInset)
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
                .padding(.horizontal, MovieBoxLayout.shelfHorizontalInset)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(records, id: \.tmdbId) { record in
                        ContinueWatchingCard(
                            record: record,
                            backdropURL: backdropURL(for: record)
                        ) {
                            action(record)
                        }
                    }
                }
                .padding(.horizontal, MovieBoxLayout.shelfHorizontalInset)
            }
        }
        .task {
            await prefetchMovieDetails()
        }
    }

    private func backdropURL(for record: MovieRecord) -> URL? {
        let movie = movieDetails[record.tmdbId]
        let bannerPath = movie?.backdropPath ?? movie?.posterPath ?? record.posterPath
        return bannerPath.flatMap { MetadataClient().imageURL(path: $0, width: 780) }
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
