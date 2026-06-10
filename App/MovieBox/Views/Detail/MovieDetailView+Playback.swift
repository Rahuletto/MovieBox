import CoreMetadata
import CorePlayer
import CoreStorage
import CoreStreaming
import CoreTorrent
import MovieBoxCore
import SwiftData
import SwiftUI

extension MovieDetailView {
    func playYouTubeVideo(_ url: URL, fallbackToRT: Bool) {
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
                        subtitleAppearance: settings.first?.subtitleAppearance ?? .modern,
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

    func isAgeRestrictionError(_ error: Error) -> Bool {
        let lowercased = error.localizedDescription.lowercased()
        return lowercased.contains("age restricted") || lowercased.contains("age-restricted")
    }

    func playTrailer() {
        isPreparingStream = true
        preparingVideoURL = nil
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

    func playTrailerRTFallback() {
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
            subtitleAppearance: settings.first?.subtitleAppearance ?? .modern,
            subtitleFontSize: settings.first?.subtitleFontSizePoints ?? 20,
            episodeTitle: "Trailer",
            displayTitle: detail?.movie.title,
            posterURL: posterURL
        )
    }

    func playBestTorrent() {
        if kind == .tv, selectedTVEpisode == nil {
            LogStore.shared.log(.warn, category: "playback", "Play Now blocked — no TV episode selected (movieId=\(movieId))")
            errorMessage = "Select a season and episode to play."
            return
        }
        if kind == .tv, let selectedTVEpisode, isUpcomingEpisode(selectedTVEpisode) {
            errorMessage = "This episode is upcoming and not available yet."
            return
        }

        guard !torrentPanel.torrents.isEmpty else {
            let imdb = detail?.imdbId ?? "nil"
            LogStore.shared.log(.warn, category: "playback", "Play Now blocked — no torrents (movieId=\(movieId) imdb=\(imdb))")
            errorMessage = torrentPanel.playFailureMessage(
                title: detail?.movie.title ?? "this title",
                kind: kind,
                imdbId: detail?.imdbId
            )
            return
        }

        let seeded = torrentPanel.torrents.filter { $0.seeders > 0 }.count
        LogStore.shared.log(
            .info,
            category: "playback",
            "Play Now tapped — movieId=\(movieId) title=\"\(detail?.movie.title ?? "?")\" torrents=\(torrentPanel.torrents.count) seeded=\(seeded) kind=\(kind.rawValue)"
        )

        Task {
            await MainActor.run { restoreSavedSubtitleSelection() }

            if subtitleFileURL == nil {
                if let saved = subtitleToDownloadWithMedia() {
                    await downloadSubtitleAsync(saved)
                } else if let preferred = subtitles.first {
                    await downloadSubtitleAsync(preferred)
                }
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
            let hasLocalFile: (TorrentResult) -> Bool = { torrent in
                appServices.resolvedCompletedMediaPath(for: torrent, downloadRecords: downloads) != nil
            }
            guard let chosen = TorrentSelection.torrentForHeroPlay(
                from: torrentPanel.torrents,
                lastStreamInfoHash: lastHash,
                hasContinueProgress: hasContinue,
                hasCompletedDownload: hasLocalFile
            ) else {
                errorMessage = torrentPanel.playFailureMessage(
                    title: detail?.movie.title ?? "this title",
                    kind: kind,
                    imdbId: detail?.imdbId
                )
                return
            }

            let playSource = hasLocalFile(chosen) ? "downloaded file" : "stream"
            LogStore.shared.log(
                .info,
                category: "playback",
                "Play — \(hasContinue ? "resume" : "fresh") \(playSource) \"\(chosen.title)\" seeders=\(chosen.seeders) quality=\(chosen.quality.rawValue)"
            )

            if let localPath = appServices.resolvedCompletedMediaPath(
                for: chosen,
                downloadRecords: downloads
            ) {
                let mediaURL = URL(fileURLWithPath: localPath)
                await downloadSubtitleForStorageDirectory(
                    mediaURL.deletingLastPathComponent(),
                    mediaPath: localPath,
                    infoHash: chosen.resolvedInfoHash
                )
            }

            playerState.onPersistSubtitleSelection = makeSubtitlePersistHandler()

            let request = PersistentPlaybackStartRequest(
                mode: .single(chosen),
                movieId: movieId,
                mediaKind: kind,
                allTorrents: torrentPanel.torrents,
                posterURL: posterURL,
                title: detail?.movie.title ?? "Playing",
                episodeTitle: episodeTitle,
                displayTitle: detail?.movie.title,
                subtitleURL: resolvedSubtitleForPlayback(
                    mediaPath: appServices.resolvedCompletedMediaPath(
                        for: chosen,
                        downloadRecords: downloads
                    ),
                    infoHash: chosen.resolvedInfoHash
                ),
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
}
