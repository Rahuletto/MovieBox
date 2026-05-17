import CoreMetadata
import CorePlayer
import CoreStorage
import CoreStreaming
import CoreTorrent
import CoreMLEngine
import DesignSystem
import SwiftData
import SwiftUI
import Combine
import AVKit
import WebKit
import UniformTypeIdentifiers

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

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
        // Escape `%` so NSLog does not treat user/API text as printf format specifiers.
        NSLog("MovieBoxApp: %@", formatted.replacingOccurrences(of: "%", with: "%%"))
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
                .animation(MovieBoxMotion.navigation, value: router.selectedRoute)

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
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(10)
            }

            AppSettingsPlaybackSync()
                .allowsHitTesting(false)
        }
        .ignoresSafeArea(edges: .top)
        .background(
            WindowConfigurator(trafficLightInset: CGPoint(x: 24, y: 20), isPlayerPresented: playerState.isPresented)
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
                        tmdbBearerToken: "",
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
            // Keep every tab mounted so ScrollView offset survives detail push/pop.
            tabStack

            if case .movieDetail(let id) = router.selectedRoute {
                MovieDetailView(
                    movieId: id,
                    kind: router.detailKind,
                    orchestrator: streamingOrchestrator,
                    onBack: { router.backFromDetail() }
                )
                .id("movie-detail-\(id)")
                .transition(.opacity)
                .zIndex(1)
            }

            // Demos disabled — see StreamTestCatalog.swift
        }
    }

    private var tabStack: some View {
        ZStack {
            HomeView()
                .opacity(router.activeTab == .home && !router.isShowingDetail ? 1 : 0)
                .allowsHitTesting(router.activeTab == .home && !router.isShowingDetail)

            CatalogView(kind: .movie)
                .opacity(router.activeTab == .movies && !router.isShowingDetail ? 1 : 0)
                .allowsHitTesting(router.activeTab == .movies && !router.isShowingDetail)

            CatalogView(kind: .tv)
                .opacity(router.activeTab == .tvShows && !router.isShowingDetail ? 1 : 0)
                .allowsHitTesting(router.activeTab == .tvShows && !router.isShowingDetail)

            LibraryView()
                .opacity(router.activeTab == .library && !router.isShowingDetail ? 1 : 0)
                .allowsHitTesting(router.activeTab == .library && !router.isShowingDetail)

            DownloadsView()
                .opacity(router.activeTab == .downloads && !router.isShowingDetail ? 1 : 0)
                .allowsHitTesting(router.activeTab == .downloads && !router.isShowingDetail)

            SearchView()
                .opacity(router.activeTab == .search && !router.isShowingDetail ? 1 : 0)
                .allowsHitTesting(router.activeTab == .search && !router.isShowingDetail)
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
let topBarReservedHeight: CGFloat = 54

// MARK: - Home (moved to Views/HomeView.swift)

// MARK: - Movie Detail (moved to Views/Detail/MovieDetailView.swift)

struct DetailHeroHeader: View {
      @Environment(\.modelContext) private var modelContext
      @Query private var storedMovies: [MovieRecord]
      
      let detail: MovieDetail
      let kind: MediaKind
      let addToMyList: () -> Void
      let onRate: (Float) -> Void
      let onPlayNow: () -> Void
      let onPlayTrailer: () -> Void
      let currentRating: Float?
      
      private var isInList: Bool {
          storedMovies.contains { $0.tmdbId == detail.movie.id }
      }
      
      var body: some View {
         VStack(alignment: .leading, spacing: 14) {
              // Logo or Title fallback
              AsyncLogoView(movieId: detail.movie.id, title: detail.movie.title, kind: kind)
              
              HStack(spacing: 8) {
                  // Prefer the real IMDb rating (from OMDB enrichment); fall back
                  // to TMDB's vote average when OMDB has nothing for this title.
                  if let imdbRating = detail.enrichment?.imdbRating {
                      GlassBadge(String(format: "%.1f IMDb", imdbRating), color: MovieBoxColors.accent)
                  } else {
                      GlassBadge(String(format: "%.1f TMDB", detail.movie.voteAverage), color: MovieBoxColors.accent)
                  }
                  if let rt = detail.enrichment?.rottenTomatoes {
                      RottenTomatoesBadge(score: rt)
                  }
                  if let runtime = detail.movie.runtime {
                      GlassBadge("\(runtime) min")
                  }
                  if let rated = detail.enrichment?.rated {
                      GlassBadge(rated)
                  }
                  ForEach(detail.genres.prefix(2)) { genre in
                      GlassBadge(genre.name)
                  }
              }
              
              Spacer()
                .frame(height: 6)
              
              HStack(spacing: 12) {
                  Button {
                      onPlayNow()
                  } label: {
                      Label("Play Now", systemImage: "play.fill")
                          .font(.headline)
                          .padding(.horizontal, 16)
                          .padding(.vertical, 8)
                          .background(.white, in: Capsule())
                          .foregroundStyle(.black)
                  }
                  .buttonStyle(.plain)
                  
                  GlassButton(action: addToMyList) {
                      Label(isInList ? "Added to List" : "Add To My List", systemImage: isInList ? "checkmark" : "plus")
                  }
              }

              if detail.trailerURL != nil {
                  Button(action: onPlayTrailer) {
                      Label("Watch Trailer (Preview)", systemImage: "play.circle")
                          .font(.subheadline)
                          .foregroundStyle(.secondary)
                  }
                  .buttonStyle(.plain)
              }
              
          }
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
                        GlassBadge(String(format: "%.1f IMDb", detail.movie.voteAverage), color: MovieBoxColors.accent)
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
                HStack(spacing: 12) {
                    // Thumbs Down (-1)
                    Button {
                        onRate(-1)
                    } label: {
                        Image(systemName: (currentRating ?? 0) == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle((currentRating ?? 0) == -1 ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dislike (-1)")
                    
                    // Heart (+1)
                    Button {
                        onRate(1)
                    } label: {
                        Image(systemName: (currentRating ?? 0) == 1 ? "heart.fill" : "heart")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle((currentRating ?? 0) == 1 ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Like (+1)")
                    
                    // Fire (+2)
                    Button {
                        onRate(2)
                    } label: {
                        Image(systemName: (currentRating ?? 0) == 2 ? "flame.fill" : "flame")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle((currentRating ?? 0) == 2 ? .orange : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Love (+2)")
                    
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
            }
        }
        .padding(28)
         .adaptiveGlass(cornerRadius: 28)
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

    

    var body: some View {
        ZStack {
            // Main content scroll view
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 36) {
                    
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
                                        subtitle: movie.releaseDate,
                                        posterURL: MetadataClient().imageURL(path: movie.posterPath),
                                        onHover: {
                                            // Warm /api/title bundle before the user clicks — by the
                                            // time the detail view loads, it's a sub-50ms KV hit.
                                            if let mode = settings.first?.metadataMode {
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
            .opacity(rows.isEmpty ? 0 : 1)
            
            // Large loading (if rows is empty)
            if isLoading && rows.isEmpty {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

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
    @Environment(AppRouter.self) private var router
    @Query private var settings: [AppSettings]
    @Query(sort: \DownloadRecord.createdAt, order: .reverse) private var downloads: [DownloadRecord]
    @StateObject private var downloadManager = DownloadManager()
    @Environment(PlayerState.self) private var playerState

    @State private var magnetInput: String = ""
    @State private var showsMagnetSheet = false
    @State private var showsTorrentFileImporter = false
    @State private var errorMessage: String? = nil
    @State private var isStreaming = false
    @State private var activeStreamSession: StreamSession? = nil
    @State private var streamingOrchestrator = StreamingOrchestrator()

    var body: some View {
        downloadsScrollContent
            .padding(.top, topBarReservedHeight)
        .navigationTitle("Downloads")
        .sheet(isPresented: $showsMagnetSheet) { magnetSheetContent }
            .fileImporter(
                isPresented: $showsTorrentFileImporter,
                allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data],
                allowsMultipleSelection: false,
                onCompletion: handleTorrentFileImport
            )
            .onAppear {
                syncMetadataBackend()
                applyPendingMagnetImport()
            }
            .onChange(of: router.pendingMagnetImport) { _, _ in
                applyPendingMagnetImport()
            }
            .onChange(of: settings.first?.proxyBaseURL) { _, _ in syncMetadataBackend() }
            .onChange(of: settings.first?.appToken) { _, _ in syncMetadataBackend() }
    }

    private var downloadsScrollContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                // demosSection — disabled (local test streams only)
                downloadsErrorBanner
                downloadsListSection
            }
        }
    }

    @ViewBuilder
    private var downloadsErrorBanner: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 28)
        }
    }

    @ViewBuilder
    private var downloadsListSection: some View {
        if downloads.isEmpty && downloadManager.tasks.isEmpty {
            ContentUnavailableView(
                "No Downloads",
                systemImage: "arrow.down.circle",
                description: Text("Download movies from details, or use File → Open Torrent / Magnet Link.")
            )
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(downloadManager.tasks) { task in
                            DownloadTaskRow(
                                task: task,
                                downloadManager: downloadManager,
                                playbackSettings: playbackSettings
                            )
                }

                ForEach(downloads, id: \.tmdbId) { download in
                    DownloadRecordRow(download: download)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
        }
    }

    private var magnetSheetContent: some View {
        MagnetImportSheet(
            magnetInput: $magnetInput,
            isStreaming: isStreaming,
            errorMessage: $errorMessage,
            onStream: { handleMagnetAction(isDownload: false) },
            onDownload: { handleMagnetAction(isDownload: true) },
            onOpenTorrentFile: { showsTorrentFileImporter = true }
        )
    }

    private func handleTorrentFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            importTorrentFile(url)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func syncMetadataBackend() {
        let config = settings.first?.backendTorrentConfig
        TorrentMetadataFetcher.configureBackend(
            baseURL: config?.baseURL,
            appToken: config?.appToken
        )
    }

    private var playbackSettings: (appearance: SubtitleAppearance, fontSize: CGFloat) {
        let settings = settings.first
        return (
            SubtitleAppearance.from(settingsValue: settings?.subtitleStyle ?? "cinematic"),
            CGFloat(settings?.subtitleFontSize ?? 20)
        )
    }

    private func playStream(url: URL, title: String, subtitleURL: URL? = nil, hdrType: PlayerHDRType? = nil) {
        errorMessage = nil
        let playback = playbackSettings
        playerState.load(
            url: url,
            title: title,
            movieId: 0,
            subtitleURL: subtitleURL,
            hdrType: hdrType,
            subtitleAppearance: playback.appearance,
            subtitleFontSize: playback.fontSize
        )
    }

    private func applyPendingMagnetImport() {
        guard let pending = router.consumePendingMagnetImport() else { return }
        magnetInput = MagnetImportHandler.normalizeUserInput(pending)
        errorMessage = nil
        showsMagnetSheet = true
    }

    private func importTorrentFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            magnetInput = try MagnetImportHandler.magnetURI(fromTorrentFileAt: url)
            errorMessage = nil
            showsMagnetSheet = true
        } catch {
            errorMessage = error.localizedDescription
            showsMagnetSheet = true
        }
    }

    private func handleMagnetAction(isDownload: Bool) {
        let cleanLink = MagnetImportHandler.normalizeUserInput(magnetInput)
        
        // Intercept direct HTTP/HTTPS stream URLs for rapid HDR/Dolby Vision testing
        if cleanLink.hasPrefix("http://") || cleanLink.hasPrefix("https://") {
            guard let url = URL(string: cleanLink) else {
                errorMessage = "Invalid stream URL format."
                return
            }
            playStream(url: url, title: "Direct stream")
            magnetInput = ""
            showsMagnetSheet = false
            return
        }
        
        var parsedLink = cleanLink
        // Convert raw 40-character info hash to full magnet link automatically
        if cleanLink.count == 40 && cleanLink.range(of: "^[a-fA-F0-9]+$", options: .regularExpression) != nil {
            parsedLink = "magnet:?xt=urn:btih:\(cleanLink)"
        }
        
        guard let magnet = MagnetURI(from: parsedLink) else {
            errorMessage = "Invalid Magnet URI or info_hash format."
            return
        }
        
        errorMessage = nil
        let displayName = magnet.displayName ?? "Custom Torrent Link"
        
        if isDownload {
            downloadManager.startDownload(
                tmdbId: Int.random(in: 100000...999999),
                title: displayName,
                magnetURI: parsedLink,
                quality: "1080p",
                hdrType: nil
            )
            magnetInput = ""
            showsMagnetSheet = false
        } else {
            guard let torrent = TorrentResult.fromMagnetURI(parsedLink, fallbackTitle: displayName) else {
                errorMessage = "Could not parse magnet link."
                return
            }

            isStreaming = true
            let coordinator = TorrentPlaybackCoordinator(orchestrator: streamingOrchestrator)
            let session = coordinator.beginStream(torrent: torrent)
            activeStreamSession = session

            Task {
                while !Task.isCancelled {
                    if case .ready = session.state { break }
                    if case .failed(let err) = session.state {
                        await MainActor.run {
                            isStreaming = false
                            errorMessage = "Streaming failed: \(err)"
                        }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }

                await MainActor.run {
                    isStreaming = false
                    do {
                        try coordinator.finishPlayback(
                            torrent: torrent,
                            allTorrents: [torrent],
                            session: session,
                            playerState: playerState,
                            movieId: 0,
                            subtitleURL: nil,
                            subtitleAppearance: playbackSettings.appearance,
                            subtitleFontSize: playbackSettings.fontSize
                        )
                        magnetInput = ""
                        showsMagnetSheet = false
                    } catch {
                        errorMessage = error.localizedDescription
                    }
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

private struct MagnetImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var magnetInput: String
    let isStreaming: Bool
    @Binding var errorMessage: String?
    let onStream: () -> Void
    let onDownload: () -> Void
    let onOpenTorrentFile: () -> Void

    private var hasInput: Bool {
        !magnetInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Open torrent", systemImage: "link.circle.fill")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text("Paste a magnet link, info hash, stream URL, or choose a .torrent file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("magnet:?xt=… or 40-char info hash", text: $magnetInput, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            Button {
                onOpenTorrentFile()
            } label: {
                Label("Choose .torrent file…", systemImage: "doc.badge.arrow.down")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if hasInput {
                    Button {
                        magnetInput = ""
                        errorMessage = nil
                    } label: {
                        Text("Clear")
                    }

                    Button {
                        onDownload()
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onStream()
                    } label: {
                        Label(isStreaming ? "Preparing…" : "Stream", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isStreaming)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

private struct DownloadTaskRow: View {
    @Environment(PlayerState.self) private var playerState
    let task: DownloadManager.DownloadTask
    let downloadManager: DownloadManager
    let playbackSettings: (appearance: SubtitleAppearance, fontSize: CGFloat)

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
                                movieId: task.tmdbId,
                                subtitleAppearance: playbackSettings.appearance,
                                subtitleFontSize: playbackSettings.fontSize
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

struct TrailerWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsAirPlayForMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 16
        webView.layer?.masksToBounds = true
        // Set transparent background for a premium dark feel
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        nsView.load(request)
    }
}

struct FullScreenTrailerPlayer: View {
    let videoURL: URL
    let onDismiss: () -> Void

    private var embedURL: URL? {
        if let key = parseYouTubeKey(from: videoURL) {
            return URL(string: "https://www.youtube.com/embed/\(key)?autoplay=1&rel=0&modestbranding=1&playsinline=1&enablejsapi=1")
        }
        return videoURL
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let embedURL {
                TrailerWebView(url: embedURL)
                    .ignoresSafeArea()
            } else {
                ContentUnavailableView("Unable to load trailer", systemImage: "play.slash")
            }

            // Elegant, floating glass-morphic close button
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(24)
            .transition(.opacity)
        }
    }

    private func parseYouTubeKey(from url: URL) -> String? {
        let absoluteString = url.absoluteString
        if absoluteString.contains("youtube.com/embed/") {
            return absoluteString.components(separatedBy: "youtube.com/embed/").last?.components(separatedBy: "?").first
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems,
           let key = queryItems.first(where: { $0.name == "v" })?.value {
            return key
        }
        if absoluteString.contains("youtu.be/") {
            return absoluteString.components(separatedBy: "youtu.be/").last?.components(separatedBy: "?").first
        }
        return nil
    }
}

private extension AppSettings {
    var cacheKey: String {
        "\(proxyBaseURL)|\(appToken)|\(tmdbBearerToken)"
    }
}
