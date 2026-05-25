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
        content.onAppear {
            playerState.onPositionUpdate = { movieId, position, duration in
                let fraction = duration > 0 ? position / duration : 0
                updateWatchHistory(tmdbId: movieId, position: position, duration: duration, fraction: fraction)
            }
        }
    }

    private func updateWatchHistory(tmdbId: Int, position: Double, duration: Double, fraction: Double) {
        guard tmdbId > 0 else { return }
        guard let record = storedMovies.first(where: { $0.tmdbId == tmdbId }) else { return }
        guard position > PlaybackDisplayTitle.minimumContinueSeconds || fraction > 0.01 else { return }

        let clampedFraction = min(1, max(fraction, 0))
        let crossedMilestone =
            (record.watchedFraction < 0.15 && clampedFraction >= 0.15) ||
            (record.watchedFraction < 0.8 && clampedFraction >= 0.8)
        let now = Date()
        let sameMovie = lastPersistedMovieId == tmdbId
        let throttleElapsed = now.timeIntervalSince(lastPersistedAt) >= 12
        guard crossedMilestone || !sameMovie || throttleElapsed else { return }

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
