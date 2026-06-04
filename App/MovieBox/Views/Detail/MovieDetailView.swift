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
    @Environment(AppRouter.self) var router
    @Environment(PlayerState.self) var playerState
    @Environment(\.modelContext) var modelContext
    @Query var settings: [AppSettings]
    @Query var storedMovies: [MovieRecord]
    @Query var ratings: [RatingRecord]
    @Query var downloads: [DownloadRecord]

    @State var detail: MovieDetail?
    @State var torrentPanel = MovieDetailTorrentPanel()
    @State var subtitles: [SubtitleInfo] = []
    @State var selectedSubtitle: SubtitleInfo?
    @State var errorMessage: String?
    @State var isLoading = false
    @State var isLoadingSubtitles = false
    @State var subtitleLoadHint: String?
    @State var subtitleFileURL: URL?
    @State var preparingVideoURL: URL?
    @State var isPreparingStream = false
    @State var tvSeasons: [TVSeasonSummary] = []
    @State var tvEpisodes: [TVEpisode] = []
    @State var selectedTVSeason = 1
    @State var selectedTVEpisode: TVEpisode?
    @State var isLoadingTVSeasons = false
    @State var isLoadingTVEpisodes = false
    @State var subtitleSearchTask: Task<Void, Never>?
    @State var subtitleSearchGeneration = 0
    @State var tvSeasonsLoadFailed = false
    let movieId: Int
    let kind: MediaKind
    @Environment(AppServices.self) var appServices
    var orchestrator: StreamingOrchestrator { appServices.streamingOrchestrator }
    let onBack: () -> Void

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
                    torrents: torrentPanel.torrents,
                    torrentSearchDiagnostics: torrentPanel.searchDiagnostics,
                    subtitles: subtitles,
                    selectedSubtitle: $selectedSubtitle,
                    isLoadingSubtitles: isLoadingSubtitles,
                    subtitleLoadHint: subtitleLoadHint,
                    subtitleFileURL: subtitleFileURL,
                    subtitleAppearance: settings.first?.subtitleAppearance ?? .modern,
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
                    isLoadingTorrents: torrentPanel.isLoading,
                    isPreparingStream: isPreparingStream,
                    preparingVideoURL: preparingVideoURL,
                    playButtonTitle: heroPlayButtonTitle,
                    playButtonDisabled: heroPlayButtonDisabled,
                    onTVSeasonChange: { season in
                        selectedTVSeason = season
                        selectedTVEpisode = nil
                        torrentPanel.reset()
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
            if kind != .tv {
                if !restoreTorrentListIfCached() {
                    torrentPanel.reset()
                }
            } else {
                torrentPanel.reset()
            }
            await load()
        }
        .keyboardShortcut(.cancelAction)
        .onKeyPress(.upArrow) {
            onBack()
            return .handled
        }
    }

    private var currentRating: Float? {
        ratings.first(where: { $0.tmdbId == movieId })?.rating
    }

    var heroPlayButtonTitle: String {
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

    var subtitleSearchContext: SubtitleSearchContext? {
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

    var heroPlayButtonDisabled: Bool {
        if kind == .tv {
            guard let episode = selectedTVEpisode else { return true }
            if isUpcomingEpisode(episode) { return true }
        }
        return torrentPanel.torrents.isEmpty
    }
}
