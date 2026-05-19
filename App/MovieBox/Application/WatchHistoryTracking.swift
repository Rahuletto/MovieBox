import CorePlayer
import CoreStorage
import MovieBoxCore
import SwiftData
import SwiftUI

struct WatchHistoryTracking: ViewModifier {
    @Environment(PlayerState.self) private var playerState
    @Environment(\.modelContext) private var modelContext
    @Query private var storedMovies: [MovieRecord]

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
        record.playbackPositionSeconds = position
        if duration.isFinite, duration > 0 {
            record.durationSeconds = duration
        }
        record.watchedFraction = min(1, max(fraction, 0))
        record.lastWatchedAt = Date()
        try? modelContext.save()
    }
}

extension View {
    func watchHistoryTracking() -> some View {
        modifier(WatchHistoryTracking())
    }
}
