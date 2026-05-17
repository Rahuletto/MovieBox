import CoreMetadata
import CorePlayer
import CoreStorage
import CoreStreaming
import CoreTorrent
import CoreMLEngine
import DesignSystem
import SwiftData
import SwiftUI
import AVKit

@MainActor
public final class LogStore {
    public static let shared = LogStore()
    public private(set) var logs: [String] = []

    public init() {}

    public func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let formatted = "[\(timestamp)] \(message)"
        logs.append(formatted)
        NSLog("MovieBoxApp: %@", formatted)
    }

    public func clear() {
        logs.removeAll()
    }

    public var allLogs: String {
        logs.joined(separator: "\n")
    }
}

struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PlayerState.self) private var playerState
    @State private var streamingOrchestrator = StreamingOrchestrator()

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .top)
                .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .center)))
                .animation(.spring(response: 0.38, dampingFraction: 0.74), value: router.selectedRoute)

            VStack(spacing: 0) {
                PillTabBar()
                    .padding(.top, 8)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(edges: .top)
            .zIndex(5)

            if playerState.isPresented {
                PlayerView(state: playerState)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(
            WindowConfigurator(trafficLightInset: CGPoint(x: 24, y: 20))
                .frame(width: 0, height: 0)
        )
        .onAppear {
            playerState.onPositionUpdate = { movieId, position, duration in
                let fraction = duration > 0 ? position / duration : 0
                updateWatchHistory(tmdbId: movieId, position: position, fraction: fraction)
            }
        }
        .task {
            LogStore.shared.log("RootView: Application launched.")
            let descriptor = FetchDescriptor<AppSettings>()
            if let existing = try? modelContext.fetch(descriptor) {
                if existing.isEmpty {
                    LogStore.shared.log("RootView: Inserting default AppSettings.")
                    let defaultSettings = AppSettings(
                        proxyBaseURL: "http://127.0.0.1:8787",
                        appToken: "165663371760d04a573abb26622164c12c508819da49dc01cc13c833d03ee9aa",
                        omdbAPIKey: "d6407590",
                        defaultDownloadPath: "~/Movies/MovieBox"
                    )
                    modelContext.insert(defaultSettings)
                    try? modelContext.save()
                } else if let first = existing.first {
                    LogStore.shared.log("RootView: Loaded AppSettings. Proxy base URL is \(first.proxyBaseURL), downloads folder is \(first.defaultDownloadPath)")
                    if first.proxyBaseURL.isEmpty || first.proxyBaseURL == "http://localhost:8787" {
                        LogStore.shared.log("RootView: Migrating legacy localhost proxy base URL to 127.0.0.1")
                        first.proxyBaseURL = "http://127.0.0.1:8787"
                        first.appToken = "165663371760d04a573abb26622164c12c508819da49dc01cc13c833d03ee9aa"
                        first.omdbAPIKey = "d6407590"
                        try? modelContext.save()
                    }
                    if first.defaultDownloadPath == "~/Downloads/MovieBox" || first.defaultDownloadPath.isEmpty {
                        LogStore.shared.log("RootView: Migrating default download path to ~/Movies/MovieBox")
                        first.defaultDownloadPath = "~/Movies/MovieBox"
                        try? modelContext.save()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            // 1. Home View
            HomeView()
                .opacity(router.activeTab == .home ? 1 : 0)
                .allowsHitTesting(router.activeTab == .home)

            // 2. Movies Catalog
            CatalogView(kind: .movie)
                .opacity(router.activeTab == .movies ? 1 : 0)
                .allowsHitTesting(router.activeTab == .movies)

            // 3. TV Shows Catalog
            CatalogView(kind: .tv)
                .opacity(router.activeTab == .tvShows ? 1 : 0)
                .allowsHitTesting(router.activeTab == .tvShows)

            // 4. Library View
            LibraryView()
                .opacity(router.activeTab == .library ? 1 : 0)
                .allowsHitTesting(router.activeTab == .library)

            // 5. Downloads View
            DownloadsView()
                .opacity(router.activeTab == .downloads ? 1 : 0)
                .allowsHitTesting(router.activeTab == .downloads)

            // 6. Search View
            SearchView()
                .opacity(router.activeTab == .search ? 1 : 0)
                .allowsHitTesting(router.activeTab == .search)

            // 7. Movie Detail View (Transient Overlay)
            if case .movieDetail(let id) = router.selectedRoute {
                MovieDetailView(movieId: id, orchestrator: streamingOrchestrator)
                    .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .center)))
                    .id("movie-detail-\(id)")
            }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Query private var storedMovies: [MovieRecord]

    private func updateWatchHistory(tmdbId: Int, position: Double, fraction: Double) {
        if let record = storedMovies.first(where: { $0.tmdbId == tmdbId }) {
            record.playbackPositionSeconds = position
            record.watchedFraction = fraction
            record.lastWatchedAt = Date()
            try? modelContext.save()
        }
    }
}

/// Approximate height reserved at the top of each screen so content scrolls
/// beneath the floating pill tab bar instead of being hidden by it.
private let topBarReservedHeight: CGFloat = 54

// MARK: - Home

struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Query private var settings: [AppSettings]
    @Query private var ratings: [RatingRecord]
    @Query private var storedMovies: [MovieRecord]
    @State private var rows: [MetadataCategory: [Movie]] = [:]
    @State private var recommended: [Movie] = []
    @State private var continueWatching: [MovieRecord] = []
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let errorMessage {
                if let mode = metadataMode {
                    RetryCard(message: errorMessage) {
                        Task { await load(mode: mode) }
                    }
                } else {
                    RetryCard(message: errorMessage) {
                        if let mode = metadataMode {
                            Task { await load(mode: mode) }
                        }
                    }
                }
            } else if metadataMode == nil {
                ContentUnavailableView(
                    "Metadata Not Configured",
                    systemImage: "key",
                    description: Text("Open Settings and add either a backend URL with app token or a TMDB bearer token.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, topBarReservedHeight)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 42) {
                        if let hero = rows[.trending]?.first {
                            HeroSection(movie: hero) {
                                router.showDetail(id: hero.id, kind: .movie)
                            }
                        }

                        if !continueWatching.isEmpty {
                            ContinueWatchingRow(records: continueWatching) { movie in
                                router.showDetail(id: movie.tmdbId, kind: .movie)
                            }
                        }

                        if !recommended.isEmpty {
                            HorizontalMovieRow(title: "Recommended For You", items: recommended) { movie in
                                MoviePosterCard(
                                    title: movie.title,
                                    subtitle: movie.releaseDate,
                                    posterURL: MetadataClient().imageURL(path: movie.posterPath)
                                ) {
                                    router.showDetail(id: movie.id, kind: .movie)
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
                                        posterURL: MetadataClient().imageURL(path: movie.posterPath)
                                    ) {
                                        router.showDetail(id: movie.id, kind: .movie)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, topBarReservedHeight)
                    .padding(.bottom, 28)
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .task(id: settingsKey) {
            guard let mode = metadataMode else { return }
            await load(mode: mode)
        }
    }

    private var metadataMode: MetadataEndpointMode? {
        settings.first?.metadataMode
    }

    private var settingsKey: String {
        settings.first?.cacheKey ?? "missing"
    }

    private func load(mode: MetadataEndpointMode) async {
        isLoading = true
        errorMessage = nil
        let client = MetadataClient(mode: mode)
        do {
            async let trending = client.movies(for: .trending)
            async let popular = client.movies(for: .popular)
            async let topRated = client.movies(for: .topRated)
            async let nowPlaying = client.movies(for: .nowPlaying)
            rows = [
                .trending: try await trending,
                .popular: try await popular,
                .topRated: try await topRated,
                .nowPlaying: try await nowPlaying
            ]

            let allMovies = (try await trending) + (try await popular) + (try await topRated)
            let ratingSignals = ratings.map { RatingSignal(tmdbId: $0.tmdbId, rating: $0.rating, genreIds: $0.genres) }
            if !ratingSignals.isEmpty {
                let engine = GenreAffinityEngine()
                let candidates = allMovies.map { RecommendationCandidate(id: $0.id, genreIds: $0.genreIds, baseScore: Float($0.voteAverage / 10)) }
                let ranked = await engine.rank(candidates: candidates, ratings: ratingSignals)
                let rankedIds = Set(ranked.map(\.id))
                recommended = allMovies.filter { rankedIds.contains($0.id) }.prefix(12).map { $0 }
            }

            continueWatching = storedMovies
                .filter { $0.watchedFraction > 0.05 && $0.watchedFraction < 0.95 }
                .sorted { ($0.lastWatchedAt ?? .distantPast) > ($1.lastWatchedAt ?? .distantPast) }
                .prefix(8)
                .map { $0 }
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }
            LogStore.shared.log("Error loading Catalog: \(error)")
            LogStore.shared.log("Stack Trace:\n\(Thread.callStackSymbols.prefix(8).joined(separator: "\n"))")
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct ContinueWatchingRow: View {
    @Environment(AppRouter.self) private var router
    let records: [MovieRecord]
    let action: (MovieRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue Watching")
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(records, id: \.tmdbId) { record in
                        Button {
                            action(record)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .frame(width: 180, height: 100)
                                    .overlay {
                                        Image(systemName: "film.stack")
                                            .font(.system(size: 28))
                                            .foregroundStyle(.secondary)
                                    }
                                    .overlay(alignment: .bottom) {
                                        ProgressView(value: record.watchedFraction)
                                            .progressViewStyle(.linear)
                                            .tint(.blue)
                                            .padding(.horizontal, 4)
                                            .padding(.bottom, 4)
                                    }

                                Text(record.title)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                    .frame(width: 180, alignment: .leading)

                                Text("\(Int(record.watchedFraction * 100))% watched")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 180, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

private struct HeroSection: View {
    let movie: Movie
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 24) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 168, height: 252)
                    .overlay {
                        Image(systemName: "film.stack")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                    }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        GlassBadge("Trending")
                        GlassBadge(String(format: "%.1f TMDB", movie.voteAverage), color: MovieBoxColors.accent)
                    }
                    Text(movie.title)
                        .font(.title)
                        .foregroundStyle(.primary)
                    Text(movie.overview)
                        .font(MovieBoxTypography.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .frame(maxWidth: 720, alignment: .leading)
                    Label("Open Detail", systemImage: "chevron.right.circle")
                        .font(.headline)
                        .foregroundStyle(.tint)
                }
                Spacer()
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 28)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Movie Detail

struct MovieDetailView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PlayerState.self) private var playerState
    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [AppSettings]
    @Query private var storedMovies: [MovieRecord]
    @Query private var ratings: [RatingRecord]
    @State private var detail: MovieDetail?
    @State private var torrents: [TorrentResult] = []
    @State private var subtitles: [SubtitleInfo] = []
    @State private var selectedSubtitle: SubtitleInfo?
    @State private var subtitleData: Data?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isLoadingSubtitles = false
    @State private var activeStreamSession: StreamSession?
    @State private var subtitleFileURL: URL?
    @State private var showTrailer = false
    @State private var trailerPlayer: AVPlayer?
    private let movieId: Int
    private let orchestrator: StreamingOrchestrator

    init(movieId: Int, orchestrator: StreamingOrchestrator) {
        self.movieId = movieId
        self.orchestrator = orchestrator
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let detail {
                    DetailHeader(
                        detail: detail,
                        addToMyList: { addToMyList(detail.movie) },
                        onRate: { rateMovie($0) },
                        onPlayTrailer: { playTrailer(detail.trailerURL) },
                        currentRating: currentRating
                    )

                    if !detail.cast.isEmpty {
                        CastSection(cast: detail.cast)
                    }

                    TorrentSection(
                        movie: detail.movie,
                        torrents: torrents,
                        orchestrator: orchestrator,
                        subtitleURL: subtitleFileURL
                    )

                    SubtitleSection(
                        movie: detail.movie,
                        subtitles: subtitles,
                        selectedSubtitle: $selectedSubtitle,
                        isLoading: isLoadingSubtitles,
                        onSearch: { searchSubtitles(for: detail.movie) },
                        onSelect: { downloadSubtitle($0) }
                    )

                    if !detail.similar.isEmpty {
                        SimilarMoviesSection(movies: detail.similar)
                    }
                } else if isLoading {
                    ProgressView("Loading movie...")
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else if let errorMessage {
                    RetryCard(message: errorMessage) {
                        Task { await load() }
                    }
                } else {
                    ContentUnavailableView("Movie Not Loaded", systemImage: "film")
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
            .padding(.top, topBarReservedHeight)
        }
        .task(id: "\(movieId)-\(router.detailKind.rawValue)-\(settingsKey)") {
            await load()
        }
        .sheet(isPresented: $showTrailer) {
            if let player = trailerPlayer {
                TrailerPlayerView(player: player, onDismiss: { showTrailer = false })
                    .frame(minWidth: 800, minHeight: 500)
            }
        }
    }

    private var currentRating: Float? {
        ratings.first(where: { $0.tmdbId == movieId })?.rating
    }

    private var settingsKey: String {
        settings.first?.cacheKey ?? "missing"
    }

    private func load() async {
        guard let mode = settings.first?.metadataMode else {
            errorMessage = "Open Settings and configure metadata access first."
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            let client = MetadataClient(mode: mode)
            let loadedDetail = try await client.movieDetail(id: movieId, kind: router.detailKind)
            detail = loadedDetail

            var latest: [TorrentResult] = []
            for await batch in await TorrentSearchAggregator().search(movieTitle: loadedDetail.movie.title) {
                latest = batch
            }
            torrents = latest

            let year = Int(loadedDetail.movie.releaseDate.prefix(4))
            let subtitleClient = SubtitleClient(mode: mode)
            subtitles = try await subtitleClient.searchSubtitles(
                title: loadedDetail.movie.title,
                year: year,
                language: settings.first?.preferredSubtitleLang ?? "en"
            )
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }
            LogStore.shared.log("Error loading Movie Detail: \(error)")
            LogStore.shared.log("Stack Trace:\n\(Thread.callStackSymbols.prefix(8).joined(separator: "\n"))")
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func addToMyList(_ movie: Movie) {
        if let existing = storedMovies.first(where: { $0.tmdbId == movie.id }) {
            existing.watchlistAddedAt = Date()
            try? modelContext.save()
            return
        }

        let record = MovieRecord(
            tmdbId: movie.id,
            title: movie.title,
            posterPath: movie.posterPath,
            genres: movie.genreIds,
            watchlistAddedAt: Date()
        )
        modelContext.insert(record)
        try? modelContext.save()
    }

    private func rateMovie(_ rating: Float) {
        if let existing = ratings.first(where: { $0.tmdbId == movieId }) {
            if rating == 0 {
                modelContext.delete(existing)
            } else {
                existing.rating = rating
                existing.ratedAt = Date()
            }
        } else if rating > 0 {
            let record = RatingRecord(
                tmdbId: movieId,
                rating: rating,
                genres: detail?.movie.genreIds ?? []
            )
            modelContext.insert(record)
        }
        try? modelContext.save()
    }

    private func searchSubtitles(for movie: Movie) {
        Task {
            isLoadingSubtitles = true
            do {
                guard let mode = settings.first?.metadataMode else { return }
                let year = Int(movie.releaseDate.prefix(4))
                let client = SubtitleClient(mode: mode)
                subtitles = try await client.searchSubtitles(
                    title: movie.title,
                    year: year,
                    language: settings.first?.preferredSubtitleLang ?? "en"
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoadingSubtitles = false
        }
    }

    private func downloadSubtitle(_ subtitle: SubtitleInfo) {
        selectedSubtitle = subtitle
        Task {
            do {
                guard let mode = settings.first?.metadataMode else { return }
                let client = SubtitleClient(mode: mode)
                let data = try await client.downloadSubtitle(url: subtitle.downloadUrl)
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("moviebox_subtitles")
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("\(subtitle.id).srt")
                try data.write(to: fileURL)
                await MainActor.run {
                    subtitleFileURL = fileURL
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func playTrailer(_ url: URL?) {
        guard let url else { return }
        trailerPlayer = AVPlayer(url: url)
        showTrailer = true
    }
}

private struct DetailHeader: View {
    let detail: MovieDetail
    let addToMyList: () -> Void
    let onRate: (Float) -> Void
    let onPlayTrailer: () -> Void
    let currentRating: Float?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(detail.movie.title)
                        .font(.title)
                        .foregroundStyle(.primary)
                    Text(detail.movie.overview)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                    HStack {
                        GlassBadge(String(format: "%.1f TMDB", detail.movie.voteAverage), color: MovieBoxColors.accent)
                        if let runtime = detail.movie.runtime {
                            GlassBadge("\(runtime) min")
                        }
                        ForEach(detail.genres.prefix(3)) { genre in
                            GlassBadge(genre.name)
                        }
                    }
                }
                Spacer()
            }

            HStack(spacing: 12) {
                GlassButton(action: addToMyList) {
                    Label("Add To My List", systemImage: "plus")
                }

                if detail.trailerURL != nil {
                    GlassButton(action: onPlayTrailer) {
                        Label("Play Trailer", systemImage: "play.circle")
                    }
                }

                Divider().frame(height: 24)

                Text("Rate:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { star in
                        Button {
                            onRate(Float(star))
                        } label: {
                            let ratingValue = currentRating ?? 0
                            Image(systemName: Float(star) <= ratingValue ? "star.fill" : "star")
                                .foregroundStyle(Float(star) <= ratingValue ? .yellow : .secondary)
                                .font(.body)
                        }
                        .buttonStyle(.plain)
                    }
                    if let currentRating, currentRating > 0 {
                        Button {
                            onRate(0)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear rating")
                    }
                }
            }
        }
        .padding(28)
        .adaptiveGlass(cornerRadius: 28)
    }
}

private struct TorrentSection: View {
    let movie: Movie
    let torrents: [TorrentResult]
    let orchestrator: StreamingOrchestrator
    let subtitleURL: URL?
    @Environment(PlayerState.self) private var playerState
    @StateObject private var downloadManager = DownloadManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Available Versions")
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)

            if torrents.isEmpty {
                ContentUnavailableView(
                    "No Versions Found",
                    systemImage: "magnifyingglass",
                    description: Text("YTS did not return torrent results for \(movie.title).")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(torrents) { torrent in
                        TorrentResultRow(
                            movieId: movie.id,
                            result: torrent,
                            orchestrator: orchestrator,
                            subtitleURL: subtitleURL,
                            downloadManager: downloadManager
                        )
                    }
                }
            }
        }
    }
}

private struct TorrentResultRow: View {
    let movieId: Int
    let result: TorrentResult
    let orchestrator: StreamingOrchestrator
    let subtitleURL: URL?
    let downloadManager: DownloadManager
    @Environment(PlayerState.self) private var playerState
    @State private var streamSession: StreamSession?
    @State private var isStreaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        GlassBadge(result.quality.rawValue)
                        if let hdr = result.hdrType {
                            GlassBadge(hdr.rawValue, color: BadgePalette.hdrColor(label: hdr.rawValue))
                        }
                        if let audio = result.audioFormat {
                            GlassBadge(audio.rawValue, color: .blue)
                        }
                        GlassBadge(result.codec.rawValue)
                        GlassBadge(result.source.rawValue)
                    }
                    HStack(spacing: 14) {
                        Text("\(result.seeders) seeders")
                            .foregroundStyle(BadgePalette.seedColor(result.seeders))
                        Text("\(result.leechers) leechers")
                        Text(result.trackerSource.label)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()

                if isStreaming, let session = streamSession {
                    StreamProgressView(session: session)
                } else {
                    HStack(spacing: 8) {
                        Button("Stream", action: startStream)
                        Button("Download", action: startDownload)
                    }
                }
            }
        }
        .padding(16)
        .adaptiveGlass(cornerRadius: 18)
    }

    private func startStream() {
        isStreaming = true
        let session = StreamSession(orchestrator: orchestrator)
        streamSession = session

        Task {
            await session.start(torrent: result)

            if case .ready(let url) = session.state {
                playerState.load(url: url, title: result.title, movieId: movieId, subtitleURL: subtitleURL)
            }
        }
    }

    private func startDownload() {
        downloadManager.startDownload(
            tmdbId: movieId,
            title: result.title,
            magnetURI: result.magnetURI,
            quality: result.quality.rawValue,
            hdrType: result.hdrType?.rawValue
        )
    }
}

private struct StreamProgressView: View {
    @ObservedObject var session: StreamSession

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            switch session.state {
            case .preparing:
                ProgressView()
                    .controlSize(.small)
                Text("Preparing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .buffering(let progress):
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                HStack(spacing: 8) {
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                    if session.downloadSpeed > 0 {
                        Text(formatSpeed(session.downloadSpeed))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if session.bufferedPieces > 0 {
                        Text("(\(session.bufferedPieces) pieces)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

            case .ready:
                Label("Streaming", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)

            case .failed(let error):
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)

            case .cancelled:
                Text("Cancelled")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .idle:
                EmptyView()
            }
        }
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        } else if bytesPerSecond >= 1000 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}

private struct CastSection: View {
    let cast: [CastMember]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast")
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(cast) { member in
                        VStack(spacing: 6) {
                            if let path = member.profilePath, let url = URL(string: "https://image.tmdb.org/t/p/w185\(path)") {
                                CachedImageView(url: url) {
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 32))
                                        .foregroundStyle(.secondary)
                                } content: { image in
                                    image.resizable().scaledToFill()
                                }
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            } else {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .frame(width: 80, height: 80)
                                    .overlay {
                                        Image(systemName: "person.circle.fill")
                                            .font(.system(size: 32))
                                            .foregroundStyle(.secondary)
                                    }
                            }

                            Text(member.name)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .frame(width: 80)

                            Text(member.character)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 80)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

private struct SubtitleSection: View {
    let movie: Movie
    let subtitles: [SubtitleInfo]
    @Binding var selectedSubtitle: SubtitleInfo?
    let isLoading: Bool
    let onSearch: () -> Void
    let onSelect: (SubtitleInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Subtitles")
                    .font(MovieBoxTypography.title)
                    .foregroundStyle(.primary)
                Spacer()
                Button("Search") {
                    onSearch()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else if subtitles.isEmpty {
                Text("No subtitles found. Try searching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(subtitles.prefix(10)) { sub in
                            SubtitleCard(
                                subtitle: sub,
                                isSelected: selectedSubtitle?.id == sub.id,
                                action: { onSelect(sub) }
                            )
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
    }
}

private struct SubtitleCard: View {
    let subtitle: SubtitleInfo
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "caption.bubble")
                        .foregroundStyle(isSelected ? .green : .secondary)
                    Text(subtitle.language.capitalized)
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                }
                Text(subtitle.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("by \(subtitle.author)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(width: 160)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.green.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.green : Color.secondary.opacity(0.2), lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SimilarMoviesSection: View {
    @Environment(AppRouter.self) private var router
    let movies: [Movie]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Similar Movies")
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(movies.prefix(12)) { movie in
                        MoviePosterCard(
                            title: movie.title,
                            subtitle: movie.releaseDate,
                            posterURL: MetadataClient().imageURL(path: movie.posterPath)
                        ) {
                            router.showDetail(id: movie.id, kind: router.detailKind)
                        }
                        .frame(width: 130)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - Catalog (Movies / TV Shows)

struct CatalogView: View {
    @Environment(AppRouter.self) private var router
    @Query private var settings: [AppSettings]

    let kind: MediaKind

    @State private var rows: [MetadataCategory: [Movie]] = [:]
    @State private var errorMessage: String?
    @State private var isLoading = false

    private var title: String { kind == .movie ? "Movies" : "TV Shows" }

    var body: some View {
        Group {
            if let errorMessage {
                RetryCard(message: errorMessage) {
                    Task { await load() }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 36) {
                        Text(title)
                            .font(MovieBoxTypography.display)
                            .padding(.horizontal, 28)
                            .padding(.top, 4)

                        if isLoading && rows.isEmpty {
                            ProgressView()
                                .controlSize(.large)
                                .frame(maxWidth: .infinity, minHeight: 260)
                        } else if rows.values.allSatisfy(\.isEmpty) {
                            ContentUnavailableView(
                                "Nothing here yet",
                                systemImage: kind == .movie ? "film" : "tv",
                                description: Text("Configure metadata access in Settings.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 260)
                        } else {
                            if let hero = rows[.trending]?.first {
                                HeroSection(movie: hero) {
                                    router.showDetail(id: hero.id, kind: kind)
                                }
                            }

                            ForEach(MetadataCategory.allCases) { category in
                                if let items = rows[category], !items.isEmpty {
                                    HorizontalMovieRow(title: category.displayTitle(for: kind), items: items) { movie in
                                        MoviePosterCard(
                                            title: movie.title,
                                            subtitle: movie.releaseDate,
                                            posterURL: MetadataClient().imageURL(path: movie.posterPath)
                                        ) {
                                            router.showDetail(id: movie.id, kind: kind)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, topBarReservedHeight)
                    .padding(.bottom, 28)
                }
                .ignoresSafeArea(edges: .top)
            }
        }
        .task(id: "\(settings.first?.cacheKey ?? "missing")|\(kind.rawValue)") {
            await load()
        }
    }

    private func load() async {
        guard let mode = settings.first?.metadataMode else {
            errorMessage = "Open Settings and configure metadata access first."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let client = MetadataClient(mode: mode)
            async let trending = client.movies(for: .trending, kind: kind)
            async let popular = client.movies(for: .popular, kind: kind)
            async let topRated = client.movies(for: .topRated, kind: kind)
            async let nowPlaying = client.movies(for: .nowPlaying, kind: kind)
            rows = [
                .trending: try await trending,
                .popular: try await popular,
                .topRated: try await topRated,
                .nowPlaying: try await nowPlaying
            ]
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }
            LogStore.shared.log("Error loading CatalogView: \(error)")
            LogStore.shared.log("Stack Trace:\n\(Thread.callStackSymbols.prefix(8).joined(separator: "\n"))")
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Downloads

struct DownloadsView: View {
    @Query(sort: \DownloadRecord.createdAt, order: .reverse) private var downloads: [DownloadRecord]
    @StateObject private var downloadManager = DownloadManager()

    var body: some View {
        ScrollView {
            if downloads.isEmpty && downloadManager.tasks.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Download movies from the Movie Detail screen.")
                )
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(downloadManager.tasks) { task in
                        DownloadTaskRow(task: task, downloadManager: downloadManager)
                    }

                    ForEach(downloads, id: \.tmdbId) { download in
                        DownloadRecordRow(download: download)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
            }
        }
        .padding(.top, topBarReservedHeight)
        .ignoresSafeArea(edges: .top)
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if downloadManager.totalDownloadSpeed > 0 {
                    Text(formatSpeed(downloadManager.totalDownloadSpeed))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        } else if bytesPerSecond >= 1000 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}

private struct DownloadTaskRow: View {
    @Environment(PlayerState.self) private var playerState
    let task: DownloadManager.DownloadTask
    let downloadManager: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        GlassBadge(task.quality)
                        if let hdr = task.hdrType {
                            GlassBadge(hdr)
                        }
                        Text(task.state.label)
                            .font(.caption)
                            .foregroundStyle(task.state.color)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(Int(task.progress * 100))%")
                        .font(.headline)
                    if task.speed > 0 {
                        Text(formatSpeed(task.speed))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ProgressView(value: task.progress)
                .progressViewStyle(.linear)

            HStack(spacing: 8) {
                switch task.state {
                case .downloading:
                    Button("Pause") { downloadManager.pauseDownload(taskId: task.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .paused:
                    Button("Resume") { downloadManager.resumeDownload(taskId: task.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Cancel", role: .destructive) { downloadManager.cancelDownload(taskId: task.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .completed:
                    Button("Watch") {
                        if let path = task.outputPath {
                            playerState.load(
                                url: URL(fileURLWithPath: path),
                                title: task.title,
                                movieId: task.tmdbId
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("Remove") { downloadManager.removeCompleted(taskId: task.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    if let path = task.outputPath {
                        Button("Show in Finder") {
                            NSWorkspace.shared.selectFile(URL(fileURLWithPath: path).path, inFileViewerRootedAtPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                case .failed:
                    Button("Retry") { downloadManager.cancelDownload(taskId: task.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                default:
                    EmptyView()
                }
            }
        }
        .padding(14)
        .adaptiveGlass(cornerRadius: 14)
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        } else if bytesPerSecond >= 1000 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}

private struct DownloadRecordRow: View {
    let download: DownloadRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(download.quality)
                    .font(.headline)
                Text(download.state)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView(value: download.progressFraction)
                .progressViewStyle(.linear)
                .frame(width: 100)
            Text("\(Int(download.progressFraction * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .adaptiveGlass(cornerRadius: 14)
    }
}

private extension DownloadState {
    var label: String {
        switch self {
        case .queued: "Queued"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    var color: Color {
        switch self {
        case .downloading: .blue
        case .completed: .green
        case .paused: .orange
        case .failed: .red
        case .queued: .secondary
        }
    }
}

// MARK: - Library (Watchlist + Downloads)

struct LibraryView: View {
    var body: some View {
        MyListView()
            .padding(.top, topBarReservedHeight)
            .ignoresSafeArea(edges: .top)
    }
}

// MARK: - My List

struct MyListView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<MovieRecord> { $0.watchlistAddedAt != nil }, sort: \MovieRecord.watchlistAddedAt, order: .reverse)
    private var movies: [MovieRecord]

    var body: some View {
        ScrollView {
            if movies.isEmpty {
                ContentUnavailableView("My List Is Empty", systemImage: "bookmark", description: Text("Add movies from the detail screen."))
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 14)], spacing: 18) {
                    ForEach(movies, id: \.tmdbId) { movie in
                        Button {
                            router.showDetail(id: movie.tmdbId, kind: .movie)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .aspectRatio(2/3, contentMode: .fit)
                                    .overlay {
                        CachedImageView(url: MetadataClient().imageURL(path: movie.posterPath)) {
                            Image(systemName: "film.stack")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                        } content: { image in
                            image.resizable().scaledToFill()
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                    .overlay(alignment: .bottomTrailing) {
                                        if movie.watchedFraction > 0.05 && movie.watchedFraction < 0.95 {
                                            GlassBadge("\(Int(movie.watchedFraction * 100))%", color: .blue)
                                                .padding(4)
                                        }
                                    }

                                Text(movie.title)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .lineLimit(1)

                                if let lastWatched = movie.lastWatchedAt {
                                    Text(lastWatched, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                movie.watchlistAddedAt = nil
                                try? modelContext.save()
                            } label: {
                                Label("Remove from List", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
            }
        }
        .navigationTitle("My List")
    }
}

// MARK: - Shared Components

struct RetryCard: View {
    let message: String
    let retry: () -> Void
    @State private var copied = false
    @Query private var settings: [AppSettings]

    var body: some View {
        VStack(spacing: 16) {
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button(action: retry) {
                    Text("Retry")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.red)
                        .clipShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    let appLogs = LogStore.shared.allLogs
                    let configSettings = settings.first
                    
                    let systemInfo = """
                    ========================================
                    MOVIEBOX DIAGNOSTIC SYSTEM ERROR REPORT
                    ========================================
                    Timestamp: \(Date().description)
                    Error: \(message)
                    
                    --- SYSTEM CONFIGURATION ---
                    Proxy Base URL: \(configSettings?.proxyBaseURL ?? "Not Configured")
                    Default Download Path: \(configSettings?.defaultDownloadPath ?? "Not Configured")
                    Preferred Quality: \(configSettings?.preferredQuality ?? "Not Configured")
                    Metadata Mode: \(String(describing: configSettings?.metadataMode))
                    Debug Logging Enabled: \(configSettings?.debugLogging ?? false ? "Yes" : "No")
                    
                    --- DIRECTORY WRITE DIAGNOSIS ---
                    Target Downloads Folder: \(configSettings?.defaultDownloadPath ?? "Not Configured")
                    Can Write Downloads Folder: \(FileManager.default.isWritableFile(atPath: (configSettings?.defaultDownloadPath as NSString?)?.expandingTildeInPath ?? "") ? "Yes" : "No")
                    
                    --- DETAILED APP WORKFLOW LOGS ---
                    \(appLogs.isEmpty ? "No logs recorded yet." : appLogs)
                    ========================================
                    """
                    
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(systemInfo, forType: .string)
                    #elseif os(iOS)
                    UIPasteboard.general.string = systemInfo
                    #endif
                    
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                        copied = true
                    }
                    
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                            copied = false
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(copied ? Color.green : Color.primary)
                        Text(copied ? "Copied!" : "Copy Logs")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(copied ? Color.green : Color.primary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.12))
                    .clipShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .adaptiveGlass(cornerRadius: 24)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

struct TrailerPlayerView: View {
    let player: AVPlayer
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Trailer")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    player.pause()
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.black)

            VideoPlayer(player: player)
                .background(.black)

            HStack {
                Button {
                    player.seek(to: CMTime(seconds: max(0, player.currentTime().seconds - 10), preferredTimescale: 600))
                } label: {
                    Image(systemName: "gobackward.10")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))

                Button {
                    if player.timeControlStatus == .playing {
                        player.pause()
                    } else {
                        player.play()
                    }
                } label: {
                    Image(systemName: player.timeControlStatus == .playing ? "pause.fill" : "play.fill")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))

                Button {
                    player.seek(to: CMTime(seconds: player.currentTime().seconds + 10, preferredTimescale: 600))
                } label: {
                    Image(systemName: "goforward.10")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))

                Spacer()

                Text(timeDisplay)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black)
        }
        .background(.black)
    }

    private var timeDisplay: String {
        let current = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        guard current.isFinite, current >= 0, duration.isFinite else { return "0:00" }
        let totalSeconds = Int(current)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d / %d:%02d", minutes, secs, Int(duration) / 60, Int(duration) % 60)
    }
}

private extension AppSettings {
    var metadataMode: MetadataEndpointMode? {
        if let url = URL(string: proxyBaseURL), !proxyBaseURL.isEmpty, !appToken.isEmpty {
            return .backend(baseURL: url, appToken: appToken)
        }
        if !tmdbBearerToken.isEmpty {
            return .direct(tmdbBearerToken: tmdbBearerToken, omdbAPIKey: omdbAPIKey.isEmpty ? nil : omdbAPIKey)
        }
        return nil
    }

    var cacheKey: String {
        "\(proxyBaseURL)|\(appToken)|\(tmdbBearerToken)"
    }
}
