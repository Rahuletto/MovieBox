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
    @Environment(AppRouter.self) private var router
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
    @State private var subtitleLoadHint: String?
    @State private var subtitleFileURL: URL?
    @State private var preparingVideoURL: URL?
    @State private var isPreparingStream = false
    @State private var tvSeasons: [TVSeasonSummary] = []
    @State private var tvEpisodes: [TVEpisode] = []
    @State private var selectedTVSeason = 1
    @State private var selectedTVEpisode: TVEpisode?
    @State private var isLoadingTVSeasons = false
    @State private var isLoadingTVEpisodes = false
    @State private var isLoadingTorrents = false
    @State private var torrentSearchTask: Task<Void, Never>?
    @State private var torrentSearchGeneration = 0
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
                    subtitleLoadHint: subtitleLoadHint,
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
                    isPreparingStream: isPreparingStream,
                    preparingVideoURL: preparingVideoURL,
                    playButtonTitle: heroPlayButtonTitle,
                    playButtonDisabled: heroPlayButtonDisabled,
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
                    onPlayTrailer: { playTrailer() },
                    onPlayVideo: { videoURL in
                        playYouTubeVideo(videoURL, fallbackToRT: false)
                    },
                    onSelectCastMember: { member in
                        router.showPerson(
                            id: member.id,
                            returningTo: .movieDetail(movieId)
                        )
                    },
                    onSearchSubtitles: { searchSubtitles(for: detail!.movie) },
                    onDownloadSubtitle: downloadSubtitle,
                    subtitleSearchContext: subtitleSearchContext
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
        .onChange(of: settings.first?.useLocalBackend) { _, _ in
            TorrentBackendSync.apply(from: settings.first)
        }
        .onChange(of: settings.first?.appToken) { _, _ in
            TorrentBackendSync.apply(from: settings.first)
        }
        .task(id: movieId) {
            isLoading = true
            detail = nil
            selectedTVEpisode = nil
            torrents = []
            torrentSearchDiagnostics = nil
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
        defer { isLoading = false }

        do {
            guard let mode = settings.first?.metadataMode else {
                throw MovieDetailLoader.LoadError.metadataNotConfigured
            }
            let client = MetadataClient(mode: mode)
            let loadedDetail = try await client.movieDetail(id: movieId, kind: kind)
            detail = loadedDetail

            isLoadingSubtitles = true
            Task {
                let subs = await MovieDetailLoader.loadSubtitles(
                    detail: loadedDetail,
                    kind: kind,
                    settings: settings.first
                )
                await MainActor.run {
                    subtitles = subs
                    isLoadingSubtitles = false
                    if subs.isEmpty {
                        if MovieDetailLoader.subtitleServiceMode(from: settings.first) == nil {
                            subtitleLoadHint = "Add your MovieBox backend URL and app token in Settings."
                        } else {
                            subtitleLoadHint = nil
                        }
                    } else {
                        subtitleLoadHint = nil
                    }
                }
            }

            if kind == .tv {
                isLoadingTVSeasons = true
                tvSeasonsLoadFailed = false
                defer { isLoadingTVSeasons = false }
                let seasons = try await client.tvSeasonSummaries(showId: movieId)
                tvSeasons = seasons
                selectedTVSeason = seasons.last(where: { $0.episodeCount > 0 })?.seasonNumber
                    ?? seasons.first?.seasonNumber
                    ?? 1

                isLoadingTVEpisodes = true
                defer { isLoadingTVEpisodes = false }
                let episodes = try await client.tvSeasonEpisodes(showId: movieId, season: selectedTVSeason)
                tvEpisodes = episodes
                selectedTVEpisode = latestReleasedEpisode(from: episodes) ?? episodes.first

                torrents = []
                torrentSearchDiagnostics = nil
                if let episode = selectedTVEpisode {
                    await selectEpisode(episode)
                }
            } else {
                Task { startTorrentSearch() }
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
            if let latestReleased = latestReleasedEpisode(from: tvEpisodes) {
                await selectEpisode(latestReleased)
            } else if let firstUpcoming = tvEpisodes.first {
                selectedTVEpisode = firstUpcoming
                torrents = []
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
        if kind == .tv {
            guard let episode = selectedTVEpisode else { return "Select Episode" }
            if isUpcomingEpisode(episode), let label = formattedAirDate(episode.airDate) {
                return "Airs \(label)"
            }
            if WatchProgressStore.resumePosition(for: movieId, in: storedMovies) != nil {
                return "Continue S\(episode.seasonNumber) E\(episode.episodeNumber)"
            }
            return "Play S\(episode.seasonNumber) E\(episode.episodeNumber)"
        }
        if WatchProgressStore.resumePosition(for: movieId, in: storedMovies) != nil {
            return "Continue Watching"
        }
        return "Play Now"
    }

    private var subtitleSearchContext: SubtitleSearchContext? {
        guard let mode = MovieDetailLoader.subtitleServiceMode(from: settings.first),
              let movie = detail?.movie else { return nil }
        return SubtitleSearchContext(
            title: movie.title,
            year: Int(movie.releaseDate.prefix(4)),
            imdbId: detail?.imdbId,
            tmdbId: movieId,
            seasonNumber: kind == .tv ? selectedTVEpisode?.seasonNumber : nil,
            episodeNumber: kind == .tv ? selectedTVEpisode?.episodeNumber : nil,
            mediaKind: kind,
            preferredLanguage: settings.first?.preferredSubtitleLang ?? "en",
            metadataMode: mode
        )
    }

    private var heroPlayButtonDisabled: Bool {
        // PlayNowButton observes persistent playback internally; avoid tying
        // the whole detail scroll view to uiTick updates here.
        if kind == .tv {
            guard let episode = selectedTVEpisode else { return true }
            if isUpcomingEpisode(episode) { return true }
        }
        return torrents.isEmpty
    }

    private func selectEpisode(_ episode: TVEpisode) async {
        selectedTVEpisode = episode
        if isUpcomingEpisode(episode) {
            torrentSearchTask?.cancel()
            torrents = []
            return
        }
        startTorrentSearch(episode: episode)
    }

    private func startTorrentSearch(episode: TVEpisode? = nil) {
        torrentSearchTask?.cancel()
        torrentSearchGeneration += 1
        let generation = torrentSearchGeneration
        torrentSearchTask = Task {
            await searchTorrents(episode: episode, generation: generation)
        }
    }

    private func searchTorrents(episode: TVEpisode? = nil, generation: Int) async {
        guard let resolvedDetail = detail else { return }
        guard !Task.isCancelled else { return }

        let searchDetail = await MovieDetailLoader.freshDetailForTorrentSearch(
            movieId: movieId,
            kind: kind,
            settings: settings.first,
            fallback: resolvedDetail
        )

        await MainActor.run {
            guard generation == torrentSearchGeneration else { return }
            self.detail = searchDetail
            isLoadingTorrents = true
            torrents = []
            torrentSearchDiagnostics = nil
        }

        for await update in MovieDetailTorrentSearch.searchStream(
            detail: searchDetail,
            kind: kind,
            settings: settings.first,
            episode: episode
        ) {
            guard !Task.isCancelled else { break }
            await MainActor.run {
                guard generation == torrentSearchGeneration else { return }
                logTorrentSearchUpdate(update)
                torrents = update.torrents
                if let diagnostics = update.diagnostics {
                    torrentSearchDiagnostics = diagnostics
                }
                if update.isComplete {
                    isLoadingTorrents = false
                    appServices.prewarmStreamingMetadata(for: torrents)
                }
            }
        }

        if Task.isCancelled { return }
        await MainActor.run {
            guard generation == torrentSearchGeneration else { return }
            isLoadingTorrents = false
        }
    }

    private func logTorrentSearchUpdate(_ update: MovieDetailTorrentSearch.ProgressUpdate) {
        let sourceCounts = Dictionary(grouping: update.torrents, by: { $0.trackerSource.label })
            .mapValues(\.count)
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        let nativeCounts = update.diagnostics?.nativeCounts
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ") ?? "nil"
        let nativeErrors = update.diagnostics?.nativeErrors
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ") ?? "nil"
        let backendURL = settings.first.map { BackendProxyURL.resolved(from: $0) } ?? "unknown"
        NSLog(
            "Torrent search update — backend=\(backendURL) complete=\(update.isComplete) visible=\(update.torrents.count) sources=[\(sourceCounts)] nativeCounts=[\(nativeCounts)] nativeErrors=[\(nativeErrors)]"
        )
    }

    private func addToMyList(_ movie: Movie) {
        if let existing = storedMovies.first(where: { $0.tmdbId == movie.id }) {
            if existing.watchlistAddedAt != nil {
                existing.watchlistAddedAt = nil
            } else {
                existing.watchlistAddedAt = Date()
                if existing.title.isEmpty { existing.title = movie.title }
                if existing.posterPath == nil { existing.posterPath = movie.posterPath }
                if existing.genres.isEmpty { existing.genres = movie.genreIds }
            }
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
                guard let mode = MovieDetailLoader.subtitleServiceMode(from: settings.first) else {
                    subtitleLoadHint = "Add your MovieBox backend URL and app token in Settings."
                    errorMessage = "Configure the MovieBox backend in Settings to search subtitles."
                    return
                }
                let year = Int(movie.releaseDate.prefix(4))
                let client = SubtitleClient(mode: mode)
                subtitles = try await client.searchSubtitles(
                    title: movie.title,
                    year: year,
                    language: "all",
                    type: kind == .tv ? "tv" : "movie",
                    imdbId: detail?.imdbId,
                    tmdbId: movieId
                )
                if !subtitles.isEmpty { subtitleLoadHint = nil }
            } catch {
                subtitleLoadHint = error.localizedDescription
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
            guard let mode = MovieDetailLoader.subtitleServiceMode(from: settings.first) else { return }
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

    private func playYouTubeVideo(_ url: URL, fallbackToRT: Bool) {
        let absoluteString = url.absoluteString
        var key: String?
        
        if absoluteString.contains("v=") {
            key = absoluteString.components(separatedBy: "v=").last?.components(separatedBy: "&").first
        } else if absoluteString.contains("embed/") {
            key = absoluteString.components(separatedBy: "embed/").last?.components(separatedBy: "?").first
        } else if absoluteString.contains("youtu.be/") {
            key = absoluteString.components(separatedBy: "youtu.be/").last?.components(separatedBy: "?").first
        }
        
        guard let trailerKey = key else {
            if !fallbackToRT {
                errorMessage = "Couldn't start this video. Try another clip or check your connection."
                return
            }
            playTrailerRTFallback()
            return
        }
        
        isPreparingStream = true
        preparingVideoURL = url
        
        Task {
            do {
                guard let mode = settings.first?.metadataMode else {
                    await MainActor.run { isPreparingStream = false }
                    return
                }
                let client = MetadataClient(mode: mode)
                let resolvedURL = try await client.resolveTrailer(key: trailerKey)
                
                await MainActor.run {
                    isPreparingStream = false
                    preparingVideoURL = nil
                    LogStore.shared.log(.info, category: "playback", "Trailer resolved — playing in AVPlayer")
                    let posterURL = detail.map {
                        MetadataClient().posterDisplayURL(
                            posterPath: $0.movie.posterPath,
                            backdropPath: $0.movie.backdropPath
                        )
                    } ?? nil
                    playerState.load(
                        url: resolvedURL,
                        title: detail?.movie.title ?? "",
                        movieId: 0,
                        subtitleURL: nil,
                        subtitleAppearance: settings.first?.subtitleAppearance ?? .cinematic,
                        subtitleFontSize: settings.first?.subtitleFontSizePoints ?? 20,
                        episodeTitle: "Trailer",
                        displayTitle: detail?.movie.title,
                        posterURL: posterURL
                    )
                }
            } catch {
                await MainActor.run {
                    isPreparingStream = false
                    preparingVideoURL = nil
                    let isAgeRestricted = isAgeRestrictionError(error)
                    if fallbackToRT {
                        LogStore.shared.log(.error, category: "playback", "Trailer resolve failed — trying RT fallback — \(error.localizedDescription)")
                    } else if isAgeRestricted {
                        LogStore.shared.log(.error, category: "playback", "Video resolve failed — age restricted")
                    } else {
                        LogStore.shared.log(.error, category: "playback", "Video resolve failed — \(error.localizedDescription)")
                    }
                }
                await MainActor.run {
                    if fallbackToRT {
                        playTrailerRTFallback()
                    } else if isAgeRestrictionError(error), detail?.trailerRTStreamURL != nil {
                        playTrailerRTFallback()
                    } else if isAgeRestrictionError(error) {
                        errorMessage = "This YouTube clip is age-restricted and cannot be resolved in-app. Try another clip or play the RT trailer."
                    } else {
                        errorMessage = "Couldn't start this video. Try another clip or check your connection."
                    }
                }
            }
        }
    }

    private func isAgeRestrictionError(_ error: Error) -> Bool {
        let lowercased = error.localizedDescription.lowercased()
        return lowercased.contains("age restricted") || lowercased.contains("age-restricted")
    }

    private func playTrailer() {
        isPreparingStream = true
        preparingVideoURL = nil
        // Prefer RT-hosted HLS when available (direct AVPlayer playback).
        if detail?.trailerRTStreamURL != nil {
            playTrailerRTFallback()
            return
        }
        if let youtubeTrailer = detail?.trailerURL {
            playYouTubeVideo(youtubeTrailer, fallbackToRT: true)
            return
        }
        playTrailerRTFallback()
    }

    private func playTrailerRTFallback() {
        guard let rtURL = detail?.trailerRTStreamURL else {
            isPreparingStream = false
            preparingVideoURL = nil
            errorMessage = "Couldn't start the trailer. Try another clip or check your connection."
            return
        }

        isPreparingStream = false
        preparingVideoURL = nil
        LogStore.shared.log(.info, category: "playback", "Playing RT trailer fallback in AVPlayer")
        let posterURL = detail.map {
            MetadataClient().posterDisplayURL(
                posterPath: $0.movie.posterPath,
                backdropPath: $0.movie.backdropPath
            )
        } ?? nil
        playerState.load(
            url: rtURL,
            title: detail?.movie.title ?? "",
            movieId: 0,
            subtitleURL: nil,
            subtitleAppearance: settings.first?.subtitleAppearance ?? .cinematic,
            subtitleFontSize: settings.first?.subtitleFontSizePoints ?? 20,
            episodeTitle: "Trailer",
            displayTitle: detail?.movie.title,
            posterURL: posterURL
        )
    }

    private func playBestTorrent() {
        if kind == .tv, selectedTVEpisode == nil {
            LogStore.shared.log(.warn, category: "playback", "Play Now blocked — no TV episode selected (movieId=\(movieId))")
            errorMessage = "Select a season and episode to play."
            return
        }
        if kind == .tv, let selectedTVEpisode, isUpcomingEpisode(selectedTVEpisode) {
            errorMessage = "This episode is upcoming and not available yet."
            return
        }

        guard !torrents.isEmpty else {
            let imdb = detail?.imdbId ?? "nil"
            LogStore.shared.log(.warn, category: "playback", "Play Now blocked — no torrents (movieId=\(movieId) imdb=\(imdb))")
            errorMessage = torrentFailureMessage(imdbId: detail?.imdbId)
            return
        }

        let seeded = torrents.filter { $0.seeders > 0 }.count
        LogStore.shared.log(
            .info,
            category: "playback",
            "Play Now tapped — movieId=\(movieId) title=\"\(detail?.movie.title ?? "?")\" torrents=\(torrents.count) seeded=\(seeded) kind=\(kind.rawValue)"
        )

        Task {
            if subtitleFileURL == nil, let preferred = subtitles.first {
                await downloadSubtitleAsync(preferred)
            }

            let playback = PlaybackSettings.from(settings.first)
            let episodeTitle = selectedTVEpisode.map {
                PlayerTVEpisodeLabel.subtitle(
                    season: $0.seasonNumber,
                    episode: $0.episodeNumber,
                    name: $0.name
                )
            }

            if let movie = detail?.movie {
                WatchProgressStore.ensureRecord(
                    movie: movie,
                    kind: kind,
                    genres: movie.genreIds,
                    in: modelContext,
                    existing: storedMovies
                )
            }

            let posterURL = detail.map {
                MetadataClient().posterDisplayURL(
                    posterPath: $0.movie.posterPath,
                    backdropPath: $0.movie.backdropPath
                )
            } ?? nil

            let resumePosition = WatchProgressStore.resumePosition(for: movieId, in: storedMovies)
            let lastHash = storedMovies.first(where: { $0.tmdbId == movieId })?.lastStreamInfoHash
            let hasContinue = resumePosition != nil
            guard let chosen = TorrentSelection.torrentForHeroPlay(
                from: torrents,
                lastStreamInfoHash: lastHash,
                hasContinueProgress: hasContinue
            ) else {
                errorMessage = torrentFailureMessage(imdbId: detail?.imdbId)
                return
            }

            LogStore.shared.log(
                .info,
                category: "playback",
                "Play — \(hasContinue ? "resume" : "fresh") torrent \"\(chosen.title)\" seeders=\(chosen.seeders) quality=\(chosen.quality.rawValue)"
            )

            let request = PersistentPlaybackStartRequest(
                mode: .single(chosen),
                movieId: movieId,
                mediaKind: kind,
                allTorrents: torrents,
                posterURL: posterURL,
                title: detail?.movie.title ?? "Playing",
                episodeTitle: episodeTitle,
                displayTitle: detail?.movie.title,
                subtitleURL: subtitleFileURL,
                subtitleCatalog: subtitles,
                selectedSubtitleID: selectedSubtitle?.id,
                subtitleSearchContext: subtitleSearchContext,
                playback: playback,
                resumePosition: resumePosition,
                knownDurationSeconds: detail?.movie.runtime.map { Double($0) * 60 },
                waitTimeout: 90,
                onPlaybackOpened: { torrent in
                    guard let record = storedMovies.first(where: { $0.tmdbId == movieId }) else { return }
                    if let hash = torrent.resolvedInfoHash {
                        record.lastStreamInfoHash = hash.lowercased()
                        try? modelContext.save()
                    }
                }
            )

            let result = appServices.persistentPlayback.start(
                request: request,
                appServices: appServices,
                playerState: playerState
            )

            if result == .needsConfirmation {
                LogStore.shared.log(.info, category: "playback", "Play Now waiting for replace confirmation")
            } else {
                LogStore.shared.log(.info, category: "playback", "Play Now started — background buffering")
            }
        }
    }

    private func latestReleasedEpisode(from episodes: [TVEpisode]) -> TVEpisode? {
        episodes
            .filter { !isUpcomingEpisode($0) }
            .max(by: { $0.episodeNumber < $1.episodeNumber })
    }

    private func isUpcomingEpisode(_ episode: TVEpisode) -> Bool {
        guard let date = parseTMDBDate(episode.airDate) else { return false }
        return date > Calendar.current.startOfDay(for: Date())
    }

    private func formattedAirDate(_ raw: String?) -> String? {
        guard let date = parseTMDBDate(raw) else { return nil }
        return MovieDetailDateFormatter.display.string(from: date)
    }

    private func parseTMDBDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return MovieDetailDateFormatter.parser.date(from: raw)
    }
}

private enum MovieDetailDateFormatter {
    static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    
    static let display: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
