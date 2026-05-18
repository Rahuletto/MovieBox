import SwiftUI
import CoreMetadata
import CoreStorage
import CoreTorrent
import CoreStreaming
import CorePlayer
import DesignSystem
import SwiftData
import AVKit

struct MovieDetailView: View {
    @Environment(PlayerState.self) private var playerState
    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [AppSettings]
    @Query private var storedMovies: [MovieRecord]
    @Query private var ratings: [RatingRecord]
    
    @State private var detail: MovieDetail?
    @State private var torrents: [TorrentResult] = []
    @State private var torrentSearchDiagnostics: TorrentSearchDiagnostics?
    @State private var subtitles: [SubtitleInfo] = []
    @State private var selectedSubtitle: SubtitleInfo?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isLoadingSubtitles = false
    @State private var subtitleFileURL: URL?
    @State private var showTrailer = false
    @State private var trailerURL: URL?
    @State private var activeStreamSession: StreamSession?
    @State private var torrentCoordinator: TorrentPlaybackCoordinator?
    @State private var isPreparingStream = false
    @State private var tvSeasons: [TVSeasonSummary] = []
    @State private var tvEpisodes: [TVEpisode] = []
    @State private var selectedTVSeason = 1
    @State private var selectedTVEpisode: TVEpisode?
    @State private var isLoadingTVSeasons = false
    @State private var isLoadingTVEpisodes = false
    @State private var isLoadingTorrents = false
    @State private var tvSeasonsLoadFailed = false
    private let movieId: Int
    private let kind: MediaKind
    private let orchestrator: StreamingOrchestrator
    private let onBack: () -> Void

    init(movieId: Int, kind: MediaKind, orchestrator: StreamingOrchestrator, onBack: @escaping () -> Void) {
        self.movieId = movieId
        self.kind = kind
        self.orchestrator = orchestrator
        self.onBack = onBack
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            FixedDetailBackdrop(backdropPath: detail?.movie.backdropPath)
                .ignoresSafeArea()

            ScrollView {
                MainContentView(
                    detail: detail,
                    isLoading: isLoading,
                    torrents: torrents,
                    torrentSearchDiagnostics: torrentSearchDiagnostics,
                    subtitles: subtitles,
                    selectedSubtitle: $selectedSubtitle,
                    isLoadingSubtitles: isLoadingSubtitles,
                    subtitleFileURL: subtitleFileURL,
                    subtitleAppearance: settings.first?.subtitleAppearance ?? .cinematic,
                    subtitleFontSize: settings.first?.subtitleFontSizePoints ?? 20,
                    currentRating: currentRating,
                    orchestrator: orchestrator,
                    kind: kind,
                    tvSeasons: tvSeasons,
                    tvEpisodes: tvEpisodes,
                    selectedTVSeason: selectedTVSeason,
                    selectedTVEpisode: selectedTVEpisode,
                    isLoadingTVSeasons: isLoadingTVSeasons,
                    isLoadingTVEpisodes: isLoadingTVEpisodes,
                    tvSeasonsLoadFailed: tvSeasonsLoadFailed,
                    isLoadingTorrents: isLoadingTorrents,
                    playButtonTitle: heroPlayButtonTitle,
                    onTVSeasonChange: { season in
                        selectedTVSeason = season
                        selectedTVEpisode = nil
                        torrents = []
                        torrentSearchDiagnostics = nil
                        Task { await loadTVEpisodes() }
                    },
                    onEpisodeSelect: { episode in
                        Task { await selectEpisode(episode) }
                    },
                    onRetryTVSeasons: {
                        Task {
                            guard let mode = settings.first?.metadataMode else { return }
                            await loadTVSeasons(client: MetadataClient(mode: mode))
                        }
                    },
                    onAddToList: { addToMyList(detail!.movie) },
                    onRate: rateMovie,
                    onPlayNow: playBestTorrent,
                    onPlayTrailer: { playTrailer(detail?.trailerURL) },
                    onSearchSubtitles: { searchSubtitles(for: detail!.movie) },
                    onDownloadSubtitle: downloadSubtitle
                )
            }
            .frame(maxWidth: .infinity)
            .clipped()
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)

            if let errorMessage {
                ErrorOverlay(message: errorMessage, onRetry: { Task { await load() } })
                    .zIndex(10)
            }

            // Preparing Stream Glass Overlay
            if isPreparingStream, let session = activeStreamSession {
                GlassStreamOverlay(session: session) {
                    Task {
                        await session.cancel()
                    }
                    isPreparingStream = false
                }
                .transition(.opacity)
                .zIndex(20)
            }

            // (Loading state is rendered inline inside MainContentView — no duplicate overlay here.)

            NavigationHeader(
                title: nil,
                shareURL: detail.map { MediaShareLink.url(for: $0, kind: kind) },
                shareTitle: detail?.movie.title,
                onBack: onBack
            )
            .zIndex(30)
        }
        .onAppear { syncMetadataBackend() }
        .onChange(of: settings.first?.proxyBaseURL) { _, _ in syncMetadataBackend() }
        .onChange(of: settings.first?.appToken) { _, _ in syncMetadataBackend() }
        .onAppear { syncMetadataBackend() }
        .onChange(of: settings.first?.proxyBaseURL) { _, _ in syncMetadataBackend() }
        .onChange(of: settings.first?.appToken) { _, _ in syncMetadataBackend() }
        .task(id: movieId) {
            selectedTVEpisode = nil
            torrents = []
            await load()
        }
        .keyboardShortcut(.cancelAction)
        .onKeyPress(.upArrow) {
            onBack()
            return .handled
        }
    }

    // MARK: - Computed Properties
    
    private var currentRating: Float? {
        ratings.first(where: { $0.tmdbId == movieId })?.rating
    }

    // MARK: - Methods
    
    private func syncMetadataBackend() {
        let config = settings.first?.backendTorrentConfig
        TorrentMetadataFetcher.configureBackend(
            baseURL: config?.baseURL,
            appToken: config?.appToken
        )
    }

    private func load() async {
        syncMetadataBackend()
        guard let mode = settings.first?.metadataMode else {
            errorMessage = "Open Settings and configure metadata access first."
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            let client = MetadataClient(mode: mode)
            // 1 RTT: backend bundle returns detail + credits + similar + external_ids
            //        + videos + pre-resolved fanart logo.
            let loadedDetail = try await client.movieDetail(id: movieId, kind: kind)
            detail = loadedDetail
            isLoadingSubtitles = true

            let preferredLang = settings.first?.preferredSubtitleLang ?? "en"
            let title = loadedDetail.movie.title
            let year = Int(loadedDetail.movie.releaseDate.prefix(4))
            let imdb = loadedDetail.imdbId
            let subtitleClient = SubtitleClient(mode: mode)

            async let subtitlesTask: [SubtitleInfo] = {
                do {
                    return try await subtitleClient.searchSubtitles(
                        title: title,
                        year: year,
                        language: preferredLang,
                        imdbId: imdb
                    )
                } catch {
                    return []
                }
            }()

            subtitles = await subtitlesTask
            isLoadingSubtitles = false

            if kind == .tv {
                torrents = []
                torrentSearchDiagnostics = nil
                selectedTVEpisode = nil
                await loadTVSeasons(client: client)
            } else {
                tvSeasons = []
                tvEpisodes = []
                selectedTVEpisode = nil
                await searchTorrents()
            }
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }
            LogStore.shared.log("Error loading Movie Detail: \(error)")
            LogStore.shared.log("Stack Trace:\n\(Thread.callStackSymbols.prefix(8).joined(separator: "\n"))")
            errorMessage = error.localizedDescription
        }
        isLoading = false
        isLoadingSubtitles = false
    }

    private func loadTVSeasons(client: MetadataClient) async {
        isLoadingTVSeasons = true
        tvSeasonsLoadFailed = false
        defer { isLoadingTVSeasons = false }
        do {
            let seasons = try await client.tvSeasonSummaries(showId: movieId)
            tvSeasons = seasons
            selectedTVSeason = seasons.last(where: { $0.episodeCount > 0 })?.seasonNumber
                ?? seasons.first?.seasonNumber
                ?? 1
            await loadTVEpisodes(client: client)
        } catch {
            tvSeasons = []
            tvEpisodes = []
            tvSeasonsLoadFailed = true
            LogStore.shared.log("TV seasons failed for \(movieId): \(error)")
        }
    }

    private func loadTVEpisodes(client: MetadataClient? = nil) async {
        guard kind == .tv, let mode = settings.first?.metadataMode else { return }
        let resolvedClient = client ?? MetadataClient(mode: mode)
        isLoadingTVEpisodes = true
        defer { isLoadingTVEpisodes = false }
        do {
            tvEpisodes = try await resolvedClient.tvSeasonEpisodes(showId: movieId, season: selectedTVSeason)
            if let first = tvEpisodes.first {
                await selectEpisode(first)
            } else {
                selectedTVEpisode = nil
                torrents = []
            }
        } catch {
            tvEpisodes = []
            selectedTVEpisode = nil
            torrents = []
        }
    }

    private var heroPlayButtonTitle: String {
        guard kind == .tv else { return "Play Now" }
        guard let episode = selectedTVEpisode else { return "Select Episode" }
        return "Play S\(episode.seasonNumber) E\(episode.episodeNumber)"
    }

    private func selectEpisode(_ episode: TVEpisode) async {
        selectedTVEpisode = episode
        await searchTorrents(episode: episode)
    }

    private func searchTorrents(episode: TVEpisode? = nil) async {
        guard let detail else { return }
        let appSettings = settings.first
        let backend = appSettings?.backendTorrentConfig
        let title = detail.movie.title
        let year = Int(detail.movie.releaseDate.prefix(4))
        let imdb = detail.imdbId
        let torrentKind: TorrentioClient.MediaKind = kind == .tv ? .tv : .movie

        let queryOverride: String? = {
            guard kind == .tv, let episode else { return nil }
            return TorrentSearchQuery.makeEpisode(
                showTitle: title,
                season: episode.seasonNumber,
                episode: episode.episodeNumber,
                year: year
            )
        }()

        isLoadingTorrents = true
        torrents = []
        defer { isLoadingTorrents = false }

        let aggregator = TorrentSearchAggregator(
            backendBaseURL: backend?.baseURL,
            backendAppToken: backend?.appToken
        )

        var latest: [TorrentResult] = []
        for await batch in aggregator.search(
            movieTitle: title,
            year: year,
            imdbId: imdb,
            kind: torrentKind,
            enabledIndexerIDs: appSettings?.enabledTorrentIndexerSet ?? TorrentIndexerPreferences.defaultIDs,
            queryOverride: queryOverride
        ) {
            latest = batch
        }

        if kind == .tv, let episode {
            latest = filterTorrents(latest, season: episode.seasonNumber, episode: episode.episodeNumber)
        }

        torrents = latest
        torrentSearchDiagnostics = await aggregator.lastDiagnostics
    }

    private func filterTorrents(_ results: [TorrentResult], season: Int, episode: Int) -> [TorrentResult] {
        let episodePatterns = [
            String(format: "S%02dE%02d", season, episode),
            String(format: "S%dE%d", season, episode),
            String(format: "%dx%02d", season, episode),
            String(format: "%dX%02d", season, episode)
        ]

        let seasonPatterns = [
            String(format: "S%02d", season),
            String(format: "S%d", season),
            String(format: "Season %02d", season),
            String(format: "Season %d", season)
        ]

        let filtered = results.filter { torrent in
            let title = torrent.title.uppercased()

            // 1. Direct episode match
            if episodePatterns.contains(where: { title.contains($0.uppercased()) }) {
                return true
            }

            // 2. Season pack match
            // To prevent matching other episode files (e.g. S01E05 when we want S01E03),
            // a season pack must match the season pattern but must NOT contain 'E' followed by a number.
            let hasSeason = seasonPatterns.contains(where: { title.contains($0.uppercased()) })
            if hasSeason {
                let isEpisodeTorrent: Bool = {
                    if let regex = try? NSRegularExpression(pattern: #"E(P|ISODE)?\s*\d+"#, options: .caseInsensitive) {
                        let range = NSRange(title.startIndex..., in: title)
                        return regex.firstMatch(in: title, options: [], range: range) != nil
                    }
                    return false
                }()

                let isPack = title.contains("COMPLETE") || title.contains("PACK") || title.contains("SEASON") || title.contains("S\(String(format: "%02d", season)) ") || title.contains("S\(season) ") || !isEpisodeTorrent

                if isPack && !isEpisodeTorrent {
                    return true
                }
            }

            return false
        }
        return filtered.isEmpty ? results : filtered
    }

    private func addToMyList(_ movie: Movie) {
        if let existing = storedMovies.first(where: { $0.tmdbId == movie.id }) {
            modelContext.delete(existing)
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
        Task { await downloadSubtitleAsync(subtitle) }
    }

    private func downloadSubtitleAsync(_ subtitle: SubtitleInfo) async {
        selectedSubtitle = subtitle
        do {
            guard let mode = settings.first?.metadataMode else { return }
            let client = SubtitleClient(mode: mode)
            let data = try await client.downloadSubtitle(url: subtitle.downloadUrl)
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("moviebox_subtitles")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("\(subtitle.id).srt")
            try data.write(to: fileURL)
            subtitleFileURL = fileURL
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func torrentFailureMessage(imdbId: String?) -> String {
        let diagnostics = torrentSearchDiagnostics ?? TorrentSearchDiagnostics()
        let missingImdb = imdbId == nil || imdbId?.isEmpty == true
        let title = detail?.movie.title ?? "this title"
        return diagnostics.playFailureMessage(title: title, isTV: kind == .tv, missingImdb: missingImdb)
    }

    private func playTrailer(_ url: URL?) {
        guard let url else { return }
        
        let absoluteString = url.absoluteString
        var key: String?
        
        if absoluteString.contains("v=") {
            key = absoluteString.components(separatedBy: "v=").last?.components(separatedBy: "&").first
        } else if absoluteString.contains("embed/") {
            key = absoluteString.components(separatedBy: "embed/").last?.components(separatedBy: "?").first
        } else if absoluteString.contains("youtu.be/") {
            key = absoluteString.components(separatedBy: "youtu.be/").last?.components(separatedBy: "?").first
        }
        
        guard let trailerKey = key else { return }
        
        isPreparingStream = true
        
        Task {
            do {
                guard let mode = settings.first?.metadataMode else { return }
                let client = MetadataClient(mode: mode)
                let resolvedURL = try await client.resolveTrailer(key: trailerKey)
                
                await MainActor.run {
                    isPreparingStream = false
                    playerState.load(
                        url: resolvedURL,
                        title: detail?.movie.title ?? "",
                        movieId: movieId,
                        subtitleURL: nil,
                        subtitleAppearance: settings.first?.subtitleAppearance ?? .cinematic,
                subtitleFontSize: settings.first?.subtitleFontSizePoints ?? 20,
                        episodeTitle: "Trailer"
                    )
                }
            } catch {
                await MainActor.run {
                    isPreparingStream = false
                    errorMessage = "Failed to resolve trailer stream: \(error.localizedDescription)"
                }
            }
        }
    }

    private func playBestTorrent() {
        if kind == .tv, selectedTVEpisode == nil {
            errorMessage = "Select a season and episode to play."
            return
        }

        guard !torrents.isEmpty else {
            errorMessage = torrentFailureMessage(imdbId: detail?.imdbId)
            return
        }

        let seeded = torrents.filter { $0.seeders > 0 }
        let candidates = seeded.isEmpty ? torrents : seeded
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
            if lhs.seeders != rhs.seeders { return lhs.seeders > rhs.seeders }
            return lhs.sizeBytes > rhs.sizeBytes
        }

        isPreparingStream = true
        let coordinator = TorrentPlaybackCoordinator(orchestrator: orchestrator)
        torrentCoordinator = coordinator

        Task {
            if subtitleFileURL == nil, let preferred = subtitles.first {
                await downloadSubtitleAsync(preferred)
            }

            var lastError: String?
            for torrent in ordered.prefix(8) {
                await coordinator.cancel()
                let session = coordinator.beginStream(torrent: torrent)
                activeStreamSession = session

                await session.waitUntilSettled(timeout: 120)

                if case .failed(let err) = session.state {
                    lastError = err
                    continue
                }

                guard case .ready = session.state else {
                    lastError = "Stream did not become ready."
                    continue
                }

                await MainActor.run {
                    withAnimation(MovieBoxMotion.player) {
                        isPreparingStream = false
                    }
                    do {
                        try coordinator.finishPlayback(
                            torrent: torrent,
                            allTorrents: torrents,
                            session: session,
                            playerState: playerState,
                            movieId: movieId,
                            subtitleURL: subtitleFileURL,
                            subtitleAppearance: settings.first?.subtitleAppearance ?? .cinematic,
                            subtitleFontSize: settings.first?.subtitleFontSizePoints ?? 20,
                            episodeTitle: selectedTVEpisode.map {
                                "S\($0.seasonNumber)E\($0.episodeNumber) · \($0.name)"
                            }
                        )
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                return
            }

            await MainActor.run {
                isPreparingStream = false
                errorMessage = lastError ?? "Could not prepare any release for streaming. Try another version."
            }
        }
    }
}

// MARK: - Subviews

/// Fixed, sharp full-window backdrop. Blur is provided by the scrolling content's
/// material background (see `ScrollFillingBlurBackground`), which naturally
/// progresses with scroll position via a GPU-accelerated backdrop filter — no
/// per-frame `.blur(radius:)` work, no gradient masks on the image itself.
private struct FixedDetailBackdrop: View {
    let backdropPath: String?

    private var backdropURL: URL? {
        guard let path = backdropPath else { return nil }
        return MetadataClient().imageURL(path: path, width: 1920)
    }

    var body: some View {
        GeometryReader { geo in
            backdropImage(size: geo.size)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
    }

    @ViewBuilder
    private func backdropImage(size: CGSize) -> some View {
        if let backdropURL {
            CachedImageView(url: backdropURL) {
                Color.clear
            } content: { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .overlay(
                        // Subtle bottom darkening for hero-text legibility while
                        // the backdrop is still uncovered (top ~60% of screen).
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 0.55),
                                .init(color: .black.opacity(0.35), location: 0.85),
                                .init(color: .black.opacity(0.75), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        } else {
            Color.clear
        }
    }
}

/// Background placed behind the scrolling content sections (below the hero).
/// Uses `.ultraThinMaterial` so the OS draws a native backdrop blur of whatever
/// sits behind it (the fixed backdrop image). As the user scrolls, this view
/// translates upward over the backdrop, so the blurred region grows naturally
/// with scroll position — efficient, no recomputation per frame.
///
/// `topExtension` lets the material start above its host view's top edge
/// (e.g. partway up the hero / backdrop image), so the blur visibly begins
/// "mid-image" before the content section itself starts.
private struct ScrollFillingBlurBackground: View {
    var topExtension: CGFloat = 360

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    // Slight dark tint for readability over bright backdrops.
                    LinearGradient(
                        colors: [Color.black.opacity(0.20), Color.black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .mask {
                    // Fixed-height eased feather at the very top of the material,
                    // then solid for the rest of the (very tall) content area.
                    // Using a fixed pixel height (not a percentage) keeps the ramp
                    // visible regardless of how long the content section is.
                    VStack(spacing: 0) {
                        LinearGradient(
                            stops: [
                                // Ease-OUT curve: gets going early, then asymptotes.
                                .init(color: .clear, location: 0.00),
                                .init(color: .white.opacity(0.12), location: 0.15),
                                .init(color: .white.opacity(0.30), location: 0.30),
                                .init(color: .white.opacity(0.50), location: 0.45),
                                .init(color: .white.opacity(0.70), location: 0.60),
                                .init(color: .white.opacity(0.85), location: 0.75),
                                .init(color: .white.opacity(0.95), location: 0.90),
                                .init(color: .white, location: 1.00)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 340)

                        Rectangle().fill(.white)
                    }
                }
                .frame(
                    width: geo.size.width,
                    height: geo.size.height + topExtension
                )
                .offset(y: -topExtension)
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }
}

/// Transparent hero — fixed backdrop shows through behind this overlay.
private struct DetailHeroOverlay: View {
    let detail: MovieDetail
    let kind: MediaKind
    let techKinds: [MediaTechKind]
    let accessibilityTags: [String]
    let playButtonTitle: String
    let addToMyList: () -> Void
    let onRate: (Float) -> Void
    let onPlayNow: () -> Void
    let onPlayTrailer: () -> Void
    let currentRating: Float?

    static let height: CGFloat = 620

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                DetailHeroHeader(
                    detail: detail,
                    kind: kind,
                    techKinds: techKinds,
                    accessibilityTags: accessibilityTags,
                    addToMyList: addToMyList,
                    onRate: onRate,
                    onPlayNow: onPlayNow,
                    onPlayTrailer: onPlayTrailer,
                    currentRating: currentRating,
                    playButtonTitle: playButtonTitle
                )
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
    }
}

private struct MainContentView: View {
    let detail: MovieDetail?
    let isLoading: Bool
    let torrents: [TorrentResult]
    let torrentSearchDiagnostics: TorrentSearchDiagnostics?
    let subtitles: [SubtitleInfo]
    @Binding var selectedSubtitle: SubtitleInfo?
    let isLoadingSubtitles: Bool
    let subtitleFileURL: URL?
    let subtitleAppearance: SubtitleAppearance
    let subtitleFontSize: CGFloat
    let currentRating: Float?
    let orchestrator: StreamingOrchestrator
    let kind: MediaKind
    let tvSeasons: [TVSeasonSummary]
    let tvEpisodes: [TVEpisode]
    let selectedTVSeason: Int
    let selectedTVEpisode: TVEpisode?
    let isLoadingTVSeasons: Bool
    let isLoadingTVEpisodes: Bool
    let tvSeasonsLoadFailed: Bool
    let isLoadingTorrents: Bool
    let playButtonTitle: String
    let onTVSeasonChange: (Int) -> Void
    let onEpisodeSelect: (TVEpisode) -> Void
    let onRetryTVSeasons: () -> Void
    let onAddToList: () -> Void
    let onRate: (Float) -> Void
    let onPlayNow: () -> Void
    let onPlayTrailer: () -> Void
    let onSearchSubtitles: () -> Void
    let onDownloadSubtitle: (SubtitleInfo) -> Void

    private var accessibilityTags: [String] {
        var tags: [String] = []
        if !subtitles.isEmpty { tags.append("CC") }
        if subtitles.contains(where: {
            $0.name.localizedCaseInsensitiveContains("SDH")
                || $0.name.localizedCaseInsensitiveContains("hearing")
        }) {
            tags.append("SDH")
        }
        return tags
    }

    private var subtitleLanguageLabels: [String] {
        Array(Set(subtitles.map(\.language))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let detail {
                    DetailHeroOverlay(
                        detail: detail,
                        kind: kind,
                        techKinds: detailTechKinds(from: torrents),
                        accessibilityTags: accessibilityTags,
                        playButtonTitle: playButtonTitle,
                        addToMyList: onAddToList,
                        onRate: onRate,
                        onPlayNow: onPlayNow,
                        onPlayTrailer: onPlayTrailer,
                        currentRating: currentRating
                    )
                    // Keep the hero above the sections VStack's blur background,
                    // which intentionally extends upward into the hero area. Without
                    // this, the material would render on top of the hero text/logo.
                    .zIndex(1)

                    VStack(alignment: .leading, spacing: 32) {
                        // Rating ALWAYS comes first
                        RatingControlsSection(currentRating: currentRating, onRate: onRate)
                            .frame(maxWidth: .infinity)

                        if kind == .tv {
                            TVEpisodesSection(
                                showId: detail.movie.id,
                                seasons: tvSeasons,
                                episodes: tvEpisodes,
                                selectedSeason: selectedTVSeason,
                                selectedEpisodeID: selectedTVEpisode?.id,
                                isLoadingSeasons: isLoadingTVSeasons,
                                seasonsLoadFailed: tvSeasonsLoadFailed,
                                isLoadingEpisodes: isLoadingTVEpisodes,
                                onSeasonChange: onTVSeasonChange,
                                onEpisodeSelect: onEpisodeSelect,
                                onRetrySeasons: onRetryTVSeasons
                            )
                            .frame(maxWidth: .infinity)
                        }

                        if kind == .tv, selectedTVEpisode != nil {
                            if isLoadingTorrents {
                                HStack(spacing: 10) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Finding streams…")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                            } else if let episode = selectedTVEpisode {
                                TorrentSection(
                                    movie: detail.movie,
                                    torrents: torrents,
                                    searchDiagnostics: torrentSearchDiagnostics,
                                    isTV: true,
                                    episodeLabel: "Season \(episode.seasonNumber) · Episode \(episode.episodeNumber)",
                                    orchestrator: orchestrator,
                                    subtitleURL: subtitleFileURL,
                                    subtitleAppearance: subtitleAppearance,
                                    subtitleFontSize: subtitleFontSize
                                )
                                .frame(maxWidth: .infinity)
                            }
                        } else if kind != .tv {
                            TorrentSection(
                                movie: detail.movie,
                                torrents: torrents,
                                searchDiagnostics: torrentSearchDiagnostics,
                                isTV: false,
                                orchestrator: orchestrator,
                                subtitleURL: subtitleFileURL,
                                subtitleAppearance: subtitleAppearance,
                                subtitleFontSize: subtitleFontSize
                            )
                            .frame(maxWidth: .infinity)
                        }

                        if !detail.cast.isEmpty {
                            CastSection(cast: detail.cast)
                                .frame(maxWidth: .infinity)
                        }

                        // Subtitles
                        SubtitleSection(
                            movie: detail.movie,
                            subtitles: subtitles,
                            selectedSubtitle: $selectedSubtitle,
                            isLoading: isLoadingSubtitles,
                            onSearch: onSearchSubtitles,
                            onSelect: onDownloadSubtitle
                        )
                        .frame(maxWidth: .infinity)

                        if !detail.similar.isEmpty {
                            SimilarMoviesSection(movies: detail.similar)
                                .frame(maxWidth: .infinity)
                        }

                        MediaInformationSection(
                            detail: detail,
                            subtitleLanguages: subtitleLanguageLabels
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, EdgeInsets.defaultHorizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ScrollFillingBlurBackground())
                } else if isLoading {
                    ProgressView("Loading movie...")
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                ContentUnavailableView("Movie Not Loaded", systemImage: "film")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RatingControlsSection: View {
    let currentRating: Float?
    let onRate: (Float) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Your Rating:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                HStack(spacing: 12) {
                    // Thumbs Down
                    Button {
                        onRate(-1)
                    } label: {
                        Image(systemName: (currentRating ?? 0) == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle((currentRating ?? 0) == -1 ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dislike (-1)")

                    // Heart
                    Button {
                        onRate(1)
                    } label: {
                        Image(systemName: (currentRating ?? 0) == 1 ? "heart.fill" : "heart")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle((currentRating ?? 0) == 1 ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Like (+1)")

                    // Fire
                    Button {
                        onRate(2)
                    } label: {
                        Image(systemName: (currentRating ?? 0) == 2 ? "flame.fill" : "flame")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle((currentRating ?? 0) == 2 ? .orange : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Love (+2)")

                    // Clear
                    if let currentRating, currentRating != 0 {
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
                Spacer()
            }
            .padding(12)
            
        }
    }
}

private struct ErrorOverlay: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            RetryCard(message: message, retry: onRetry)
                .frame(maxWidth: 420)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Responsive Padding Helper

private struct EdgeInsets {
    static var defaultHorizontalPadding: CGFloat {
        // Responsive: use smaller padding on compact, larger on regular
        return 28
    }
}

private struct GlassStreamOverlay: View {
    @ObservedObject var session: StreamSession
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 20) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)

                    Text("Preparing Stream")
                        .font(.headline)
                        .foregroundStyle(.white)

                    switch session.state {
                    case .preparing:
                        Text("Connecting to seeders...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    case .buffering:
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.regular)
                                .tint(.white)

                            Text("Buffering first chunk…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            HStack {
                                if session.bufferedBytes > 0 {
                                    Text(formatBytes(session.bufferedBytes))
                                }
                                Spacer()
                                if session.downloadSpeed > 0 {
                                    Text(formatSpeed(session.downloadSpeed))
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        }
                    case .ready:
                        Text("Ready to play!")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    case .failed(let error):
                        Text("Failed: \(error)")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    case .cancelled:
                        Text("Cancelled")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    case .idle:
                        EmptyView()
                    }

                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(32)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
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

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_048_576 {
            return String(format: "%.1f MB buffered", Double(bytes) / 1_048_576)
        }
        if bytes >= 1024 {
            return String(format: "%.0f KB buffered", Double(bytes) / 1024)
        }
        return "\(bytes) B buffered"
    }
}
