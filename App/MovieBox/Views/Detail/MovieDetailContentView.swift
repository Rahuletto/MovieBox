import CoreMetadata
import CorePlayer
import CoreStreaming
import CoreTorrent
import MovieBoxCore
import SwiftUI

struct MovieDetailContentView: View {
    let detail: MovieDetail?
    let isLoading: Bool
    let torrents: [TorrentResult]
    let torrentSearchDiagnostics: TorrentSearchDiagnostics?
    let subtitles: [SubtitleInfo]
    @Binding var selectedSubtitle: SubtitleInfo?
    let isLoadingSubtitles: Bool
    let subtitleLoadHint: String?
    let subtitleFileURL: URL?
    let subtitleAppearance: SubtitleAppearance
    let subtitleFontSize: CGFloat
    let currentRating: Float?
    let kind: MediaKind
    let tvSeasons: [TVSeasonSummary]
    let tvEpisodes: [TVEpisode]
    let selectedTVSeason: Int
    let selectedTVEpisode: TVEpisode?
    let isLoadingTVSeasons: Bool
    let isLoadingTVEpisodes: Bool
    let tvSeasonsLoadFailed: Bool
    let isLoadingTorrents: Bool
    let isPreparingStream: Bool
    let preparingVideoURL: URL?
    let playButtonTitle: String
    let playButtonDisabled: Bool
    let onTVSeasonChange: (Int) -> Void
    let onEpisodeSelect: (TVEpisode) -> Void
    let onRetryTVSeasons: () -> Void
    let onAddToList: () -> Void
    let onRate: (Float) -> Void
    let onPlayNow: () -> Void
    let onPlayTrailer: () -> Void
    let onPlayVideo: (URL) -> Void
    let onSelectCastMember: (CastMember) -> Void
    let onSearchSubtitles: () -> Void
    let onDownloadSubtitle: (SubtitleInfo) -> Void
    let subtitleSearchContext: SubtitleSearchContext?

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
                    playButtonDisabled: playButtonDisabled,
                    addToMyList: onAddToList,
                    onRate: onRate,
                    onPlayNow: onPlayNow,
                    onPlayTrailer: onPlayTrailer,
                    isPreparingTrailer: isPreparingStream && preparingVideoURL == nil,
                    currentRating: currentRating
                )
                .zIndex(1)

                VStack(alignment: .leading, spacing: 32) {
                    DetailRatingControlsSection(currentRating: currentRating, onRate: onRate)
                        .frame(maxWidth: .infinity)

                    if !detail.videos.isEmpty {
                        detailShelfSection {
                            TrailersClipsSection(
                                videos: detail.videos,
                                onPlay: onPlayVideo,
                                isPreparingStream: isPreparingStream,
                                preparingVideoURL: preparingVideoURL
                            )
                        }
                    }

                    if kind == .tv {
                        detailShelfSection {
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
                        }
                    }

                    if kind == .tv, selectedTVEpisode != nil, let episode = selectedTVEpisode {
                        TorrentSection(
                            movie: detail.movie,
                            torrents: torrents,
                            searchDiagnostics: torrentSearchDiagnostics,
                            isLoading: isLoadingTorrents,
                            isTV: true,
                            episodeLabel: PlayerTVEpisodeLabel.subtitle(
                                season: episode.seasonNumber,
                                episode: episode.episodeNumber,
                                name: episode.name
                            ),
                            subtitleURL: subtitleFileURL,
                            subtitleCatalog: subtitles,
                            selectedSubtitleID: selectedSubtitle?.id,
                            subtitleSearchContext: subtitleSearchContext,
                            subtitleAppearance: subtitleAppearance,
                            subtitleFontSize: subtitleFontSize
                        )
                        .id(episode.id)
                        .frame(maxWidth: .infinity)
                    } else if kind != .tv {
                        TorrentSection(
                            movie: detail.movie,
                            torrents: torrents,
                            searchDiagnostics: torrentSearchDiagnostics,
                            isLoading: isLoadingTorrents || (isLoading && torrents.isEmpty),
                            isTV: false,
                            subtitleURL: subtitleFileURL,
                            subtitleCatalog: subtitles,
                            selectedSubtitleID: selectedSubtitle?.id,
                            subtitleSearchContext: subtitleSearchContext,
                            subtitleAppearance: subtitleAppearance,
                            subtitleFontSize: subtitleFontSize
                        )
                        .frame(maxWidth: .infinity)
                    }

                    if !detail.cast.isEmpty {
                        detailShelfSection {
                            CastSection(cast: detail.cast) { member in
                                onSelectCastMember(member)
                            }
                        }
                    }

                    SubtitleSection(
                        movie: detail.movie,
                        subtitles: subtitles,
                        selectedSubtitle: $selectedSubtitle,
                        isLoading: isLoadingSubtitles,
                        emptyHint: subtitleLoadHint,
                        onSearch: onSearchSubtitles,
                        onSelect: onDownloadSubtitle
                    )
                    .frame(maxWidth: .infinity)

                    if !detail.similar.isEmpty {
                        detailShelfSection {
                            SimilarMoviesSection(movies: detail.similar)
                        }
                    }

                    MediaInformationSection(
                        detail: detail,
                        subtitleLanguages: subtitleLanguageLabels
                    )
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, DetailLayoutMetrics.horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ScrollFillingBlurBackground())
            } else if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .padding(.top, 24)
            } else {
                ContentUnavailableView("Movie Not Loaded", systemImage: "film")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detailShelfSection<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, -DetailLayoutMetrics.horizontalPadding)
    }
}
