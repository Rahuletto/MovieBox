import CoreMetadata
import CorePlayer
import CoreStorage
import MovieBoxCore
import SwiftData
import SwiftUI

struct WatchHistoryTracking: ViewModifier {
    @Environment(PlayerState.self) private var playerState
    @Environment(\.modelContext) private var modelContext
    @Query private var storedMovies: [MovieRecord]

    @State private var lastPersistedAt: Date = .distantPast
    @State private var lastPersistedMovieId: Int = 0

    func body(content: Content) -> some View {
        content
            .onAppear {
                playerState.onPositionUpdate = { movieId, position, duration in
                    let fraction = duration > 0 ? position / duration : 0
                    updateWatchHistory(
                        tmdbId: movieId,
                        position: position,
                        duration: duration,
                        fraction: fraction,
                        force: false
                    )
                }
            }
            .onChange(of: playerState.isPresented) { _, isPresented in
                guard !isPresented else { return }
                flushWatchHistoryOnDismiss()
            }
    }

    private func flushWatchHistoryOnDismiss() {
        let movieId = playerState.movieId
        guard movieId > 0 else { return }
        let duration = playerState.duration
        guard duration > 0 else { return }
        let position = playerState.reportedPlaybackPosition
        let fraction = position / duration
        updateWatchHistory(
            tmdbId: movieId,
            position: position,
            duration: duration,
            fraction: fraction,
            force: true
        )
    }

    private func updateWatchHistory(
        tmdbId: Int,
        position: Double,
        duration: Double,
        fraction: Double,
        force: Bool
    ) {
        guard tmdbId > 0 else { return }
        guard force || position > PlaybackDisplayTitle.minimumContinueSeconds || fraction > 0.01 else { return }

        let record: MovieRecord
        if let existing = storedMovies.first(where: { $0.tmdbId == tmdbId }) {
            record = existing
        } else {
            let hudTitle = playerState.seriesName.isEmpty
                ? playerState.title
                : playerState.seriesName
            guard let created = WatchProgressStore.ensurePlaybackRecord(
                tmdbId: tmdbId,
                title: hudTitle,
                mediaKind: .movie,
                in: modelContext,
                existing: storedMovies
            ) else { return }
            record = created
        }

        let clampedFraction = min(1, max(fraction, 0))
        if !force {
            let crossedMilestone =
                (record.watchedFraction < 0.15 && clampedFraction >= 0.15) ||
                (record.watchedFraction < 0.8 && clampedFraction >= 0.8)
            let now = Date()
            let sameMovie = lastPersistedMovieId == tmdbId
            let throttleElapsed = now.timeIntervalSince(lastPersistedAt) >= 12
            guard crossedMilestone || !sameMovie || throttleElapsed else { return }
        }
        let now = Date()

        record.playbackPositionSeconds = position
        if duration.isFinite, duration > 0 {
            record.durationSeconds = duration
        }
        record.watchedFraction = clampedFraction
        record.lastWatchedAt = now
        if record.mediaKindEnum == .tv,
           let index = playerState.currentEpisodeIndex,
           playerState.episodes.indices.contains(index) {
            let episode = playerState.episodes[index]
            record.lastWatchedSeason = episode.seasonNumber
            record.lastWatchedEpisode = episode.episodeNumber
        }
        try? modelContext.save()
        lastPersistedAt = now
        lastPersistedMovieId = tmdbId
    }
}

extension View {
    func watchHistoryTracking() -> some View {
        modifier(WatchHistoryTracking())
    }
}
