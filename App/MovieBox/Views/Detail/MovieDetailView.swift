import AVKit
import CoreMetadata
import CorePlayer
import CoreStorage
import CoreStreaming
import CoreTorrent
import DesignSystem
import MovieBoxCore
import MovieBoxDetail
import SwiftData
import SwiftUI

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
    @State private var activeStreamSession: TorrentStreamSession?
    @State private var isPreparingStream = false
    /// Cancels an in-flight `playBestTorrent` attempt when the user starts another play.
    @State private var prepareStreamTask: Task<Void, Never>?
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
    @Environment(AppServices.self) private var appServices
    private var orchestrator: StreamingOrchestrator { appServices.streamingOrchestrator }
    private let onBack: () -> Void

    init(movieId: Int, kind: MediaKind, onBack: @escaping () -> Void) {
        self.movieId = movieId
        self.kind = kind
        self.onBack = onBack
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            FixedDetailBackdrop(backdropPath: detail?.movie.backdropPath)
                .ignoresSafeArea()

            ScrollView {
                MovieDetailContentView(
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
                        Task { await loadTVSeasons() }
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
                DetailErrorOverlay(message: errorMessage, onRetry: { Task { await load() } })
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
        .onAppear { TorrentBackendSync.apply(from: settings.first) }
        .onChange(of: settings.first?.proxyBaseURL) { _, _ in
            TorrentBackendSync.apply(from: settings.first)
        }
        .onChange(of: settings.first?.appToken) { _, _ in
            TorrentBackendSync.apply(from: settings.first)
        }
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
    
    private func load() async {
        TorrentBackendSync.apply(from: settings.first)
        isLoading = true
        errorMessage = nil
        isLoadingSubtitles = true
        defer {
            isLoading = false
            isLoadingSubtitles = false
        }

        do {
            let loaded = try await MovieDetailLoader.load(
                movieId: movieId,
                kind: kind,
                settings: settings.first
            )
            detail = loaded.detail
            subtitles = loaded.subtitles
            tvSeasons = loaded.tvSeasons
            tvEpisodes = loaded.tvEpisodes
            selectedTVSeason = loaded.selectedSeason
            selectedTVEpisode = loaded.selectedEpisode

            if kind == .tv {
                torrents = []
                torrentSearchDiagnostics = nil
                if let episode = loaded.selectedEpisode {
                    await selectEpisode(episode)
                }
            } else {
                await searchTorrents()
            }
        } catch let loadError as MovieDetailLoader.LoadError {
            errorMessage = loadError.errorDescription
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled { return }
            MetadataErrorLogger.record(error, context: "Movie detail")
            errorMessage = error.localizedDescription
        }
    }

    private func loadTVSeasons() async {
        isLoadingTVSeasons = true
        tvSeasonsLoadFailed = false
        defer { isLoadingTVSeasons = false }
        do {
            let seasons = try await MovieDetailLoader.loadTVSeasons(
                showId: movieId,
                settings: settings.first
            )
            tvSeasons = seasons
            selectedTVSeason = seasons.last(where: { $0.episodeCount > 0 })?.seasonNumber
                ?? seasons.first?.seasonNumber
                ?? 1
            await loadTVEpisodes()
        } catch {
            tvSeasons = []
            tvEpisodes = []
            tvSeasonsLoadFailed = true
            MetadataErrorLogger.record(error, context: "TV seasons \(movieId)")
        }
    }

    private func loadTVEpisodes() async {
        guard kind == .tv else { return }
        isLoadingTVEpisodes = true
        defer { isLoadingTVEpisodes = false }
        do {
            tvEpisodes = try await MovieDetailLoader.loadTVEpisodes(
                showId: movieId,
                season: selectedTVSeason,
                settings: settings.first
            )
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
        isLoadingTorrents = true
        torrents = []
        defer { isLoadingTorrents = false }

        let result = await MovieDetailTorrentSearch.search(
            detail: detail,
            kind: kind,
            settings: settings.first,
            episode: episode
        )
        torrents = result.torrents
        torrentSearchDiagnostics = result.diagnostics
    }

    private func addToMyList(_ movie: Movie) {
        if let existing = storedMovies.first(where: { $0.tmdbId == movie.id }) {
            modelContext.delete(existing)
            try? modelContext.save()
            return
        }

        let record = MovieRecord(
            tmdbId: movie.id,
            mediaKind: kind.storageValue,
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
        MovieDetailTorrentSearch.playFailureMessage(
            diagnostics: torrentSearchDiagnostics,
            title: detail?.movie.title ?? "this title",
            kind: kind,
            imdbId: imdbId
        )
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

        isPreparingStream = true
        prepareStreamTask?.cancel()

        prepareStreamTask = Task {
            if subtitleFileURL == nil, let preferred = subtitles.first {
                await downloadSubtitleAsync(preferred)
            }

            let playback = PlaybackSettings.from(settings.first)
            let episodeTitle = selectedTVEpisode.map {
                "S\($0.seasonNumber)E\($0.episodeNumber) · \($0.name)"
            }

            do {
                try await TorrentPlaybackService.playBestAvailable(
                    torrents: torrents,
                    movieId: movieId,
                    subtitleURL: subtitleFileURL,
                    playback: playback,
                    episodeTitle: episodeTitle,
                    appServices: appServices,
                    playerState: playerState,
                    onSessionStarted: { session in
                        activeStreamSession = session
                    }
                )
                withAnimation(MovieBoxMotion.player) {
                    isPreparingStream = false
                }
            } catch {
                isPreparingStream = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

