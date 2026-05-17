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
    @State private var scrollOffset: CGFloat = 0
    
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
            // Fixed, full-window backdrop image — sits behind everything and
            // doesn't scroll. The scroll content has its own opaque background
            // below the hero area, so the backdrop is only visible at the top.
            FixedDetailBackdrop(
                backdropPath: detail?.movie.backdropPath,
                scrollOffset: scrollOffset
            )
            .ignoresSafeArea()

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
                currentRating: currentRating,
                scrollOffset: $scrollOffset,
                orchestrator: orchestrator,
                kind: kind,
                onAddToList: { addToMyList(detail!.movie) },
                onRate: rateMovie,
                onPlayNow: playBestTorrent,
                onPlayTrailer: { playTrailer(detail?.trailerURL) },
                onSearchSubtitles: { searchSubtitles(for: detail!.movie) },
                onDownloadSubtitle: downloadSubtitle
            )

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

            // Navigation header with back button (on top)
            NavigationHeader(title: nil, onBack: onBack)
        }
        .onAppear { syncMetadataBackend() }
        .onChange(of: settings.first?.proxyBaseURL) { _, _ in syncMetadataBackend() }
        .onChange(of: settings.first?.appToken) { _, _ in syncMetadataBackend() }
        .onAppear { syncMetadataBackend() }
        .onChange(of: settings.first?.proxyBaseURL) { _, _ in syncMetadataBackend() }
        .onChange(of: settings.first?.appToken) { _, _ in syncMetadataBackend() }
        .task(id: movieId) {
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

            // Torrent search + subtitle search run in parallel — neither depends on
            // the other, and we no longer block one behind the other sequentially.
            async let torrentsTask: ([TorrentResult], TorrentSearchDiagnostics) = {
                let appSettings = settings.first
                let backend = appSettings?.backendTorrentConfig
                let aggregator = TorrentSearchAggregator(
                    backendBaseURL: backend?.baseURL,
                    backendAppToken: backend?.appToken
                )
                var latest: [TorrentResult] = []
                let torrentKind: TorrentioClient.MediaKind = kind == .tv ? .tv : .movie
                for await batch in aggregator.search(
                    movieTitle: title,
                    year: year,
                    imdbId: imdb,
                    kind: torrentKind,
                    enabledIndexerIDs: appSettings?.enabledTorrentIndexerSet ?? TorrentIndexerPreferences.defaultIDs
                ) {
                    latest = batch
                }
                return (latest, await aggregator.lastDiagnostics)
            }()

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

            let torrentSearch = await torrentsTask
            torrents = torrentSearch.0
            torrentSearchDiagnostics = torrentSearch.1
            if torrents.isEmpty {
                LogStore.shared.log(
                    "Torrent search empty for \"\(torrentSearch.1.queryUsed)\" (torrentio: \(torrentSearch.1.torrentioCount), native: \(torrentSearch.1.nativeTotalCount), detail: \(torrentSearch.1.nativeCounts))."
                )
            }
            subtitles = await subtitlesTask
            isLoadingSubtitles = false
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

                var failed = false
                while !Task.isCancelled {
                    if case .ready = session.state { break }
                    if case .failed(let err) = session.state {
                        lastError = err
                        failed = true
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }

                if failed { continue }

                await MainActor.run {
                    isPreparingStream = false
                    do {
                        try coordinator.finishPlayback(
                            torrent: torrent,
                            allTorrents: torrents,
                            session: session,
                            playerState: playerState,
                            movieId: movieId,
                            subtitleURL: subtitleFileURL,
                            subtitleAppearance: settings.first?.subtitleAppearance ?? .cinematic
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

/// Fixed, full-window backdrop that sits behind the entire detail view.
/// Doesn't scroll; the scroll content has its own opaque background that covers
/// the backdrop everywhere except inside the hero overlay area at the top.
///
/// Layout safety:
/// - `GeometryReader` gives a known size, so the image always fills its parent
///   without intrinsic-size negotiation that could push siblings around.
/// - `.clipped()` keeps oversized source images inside the frame.
/// - The vertical gradient fades cleanly into the opaque content section below,
///   so there's no visible seam.
private struct FixedDetailBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    let backdropPath: String?
    let scrollOffset: CGFloat

    /// Fade color matches the surrounding chrome — black in dark mode,
    /// white in light mode — so the backdrop dissolves into the page
    /// background instead of awkwardly fading to black under a white UI.
    private var fadeColor: Color {
        colorScheme == .dark ? .black : .white
    }

    var body: some View {
        // Scroll-driven blur + tinted overlay: as the user scrolls down,
        // `scrollOffset` goes negative; we map that to a blur radius and a
        // fade-color alpha so the backdrop softly dissolves into the
        // content below. Same shape as the old `BackdropBackground`,
        // applied to a fixed full-window backdrop.
        let blurAmount = min(max(-scrollOffset / 20, 0), 32)
        let fadeOpacity = min(max(-scrollOffset / 300, 0), 0.5)

        GeometryReader { geo in
            ZStack {
                fadeColor
                if let path = backdropPath,
                   let url = MetadataClient().imageURL(path: path, width: 1920) {
                    CachedImageView(url: url) {
                        fadeColor
                    } content: { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .blur(radius: blurAmount)
                    }
                }

                // Scroll-driven fade overlay — same alpha-channel pattern as
                // the previous `BackdropBackground`, tinted by `fadeColor`.
                fadeColor.opacity(fadeOpacity)

                // Subtle constant vertical fade so hero text always has
                // legible contrast even at scrollOffset == 0.
                LinearGradient(
                    colors: [.clear, fadeColor.opacity(0.1)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Horizontal vignette from the left.
                LinearGradient(
                    colors: [fadeColor.opacity(0.3), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }
}

/// Transparent hero overlay — no backdrop image (that's the fixed background),
/// just a hero header pinned to the bottom-left at a known height. Sits at the
/// top of the scroll content so the backdrop shows through.
private struct DetailHeroOverlay: View {
    let detail: MovieDetail
    let kind: MediaKind
    let addToMyList: () -> Void
    let onRate: (Float) -> Void
    let onPlayNow: () -> Void
    let onPlayTrailer: () -> Void
    let currentRating: Float?

    /// Fixed height so layout never shifts and content below always lands in
    /// the same spot.
    static let height: CGFloat = 540

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack {
                DetailHeroHeader(
                    detail: detail,
                    kind: kind,
                    addToMyList: addToMyList,
                    onRate: onRate,
                    onPlayNow: onPlayNow,
                    onPlayTrailer: onPlayTrailer,
                    currentRating: currentRating
                )
                .frame(maxWidth: 720, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
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
    let currentRating: Float?
    @Binding var scrollOffset: CGFloat
    let orchestrator: StreamingOrchestrator
    let kind: MediaKind
    let onAddToList: () -> Void
    let onRate: (Float) -> Void
    let onPlayNow: () -> Void
    let onPlayTrailer: () -> Void
    let onSearchSubtitles: () -> Void
    let onDownloadSubtitle: (SubtitleInfo) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let detail {
                    // Transparent hero overlay at the top of the scroll content
                    // so the fixed backdrop behind the view shows through. Fixed
                    // height means no layout shift while the backdrop loads.
                    DetailHeroOverlay(
                        detail: detail,
                        kind: kind,
                        addToMyList: onAddToList,
                        onRate: onRate,
                        onPlayNow: onPlayNow,
                        onPlayTrailer: onPlayTrailer,
                        currentRating: currentRating
                    )

                    VStack(alignment: .leading, spacing: 24) {
                        // Rating Controls
                        RatingControlsSection(currentRating: currentRating, onRate: onRate)
                            .frame(maxWidth: .infinity)

                        // Cast
                        if !detail.cast.isEmpty {
                            CastSection(cast: detail.cast)
                                .frame(maxWidth: .infinity)
                        }

                        // Torrents
                        TorrentSection(
                            movie: detail.movie,
                            torrents: torrents,
                            searchDiagnostics: torrentSearchDiagnostics,
                            isTV: kind == .tv,
                            orchestrator: orchestrator,
                            subtitleURL: subtitleFileURL,
                            subtitleAppearance: subtitleAppearance
                        )
                        .frame(maxWidth: .infinity)

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

                        // Similar Movies
                        if !detail.similar.isEmpty {
                            SimilarMoviesSection(movies: detail.similar)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, EdgeInsets.defaultHorizontalPadding)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
//                    .background(Color(nsColor: .windowBackgroundColor))
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
        .frame(maxWidth: .infinity)
        .clipped()
        .scrollContentBackground(.hidden)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            -geometry.contentOffset.y
        } action: { _, newOffset in
            scrollOffset = newOffset
        }
        .scrollIndicators(.hidden)
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
                    case .buffering(let progress):
                        VStack(spacing: 8) {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .tint(.white)
                                .frame(width: 200)
                            
                            HStack {
                                Text("\(Int(progress * 100))%")
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
}
