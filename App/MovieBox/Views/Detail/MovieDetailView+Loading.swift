import CoreMetadata
import CoreTorrent
import MovieBoxCore
import MovieBoxDetail
import SwiftUI

extension MovieDetailView {
    func load() async {
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

            if kind != .tv {
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
                            restoreSavedSubtitleSelection()
                        }
                    }
                }
            } else {
                isLoadingSubtitles = false
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

                torrentPanel.reset()
                if let episode = selectedTVEpisode {
                    await selectEpisode(episode)
                }
            } else if !restoreTorrentListIfCached() {
                startTorrentSearch()
            }
        } catch let loadError as MovieDetailLoader.LoadError {
            errorMessage = loadError.errorDescription
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled { return }
            MetadataErrorLogger.record(error, context: "Movie detail")
            errorMessage = error.localizedDescription
        }
    }

    func loadTVSeasons() async {
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

    func loadTVEpisodes() async {
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
                torrentPanel.reset()
            } else {
                selectedTVEpisode = nil
                torrentPanel.reset()
            }
        } catch {
            tvEpisodes = []
            selectedTVEpisode = nil
            torrentPanel.reset()
        }
    }
}
