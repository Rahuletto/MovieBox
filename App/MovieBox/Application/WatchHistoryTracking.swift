import CorePlayer
import CoreStorage
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
                updateWatchHistory(tmdbId: movieId, position: position, fraction: fraction)
            }
        }
    }

    private func updateWatchHistory(tmdbId: Int, position: Double, fraction: Double) {
        guard tmdbId > 0 else { return }
        if let record = storedMovies.first(where: { $0.tmdbId == tmdbId }) {
            record.playbackPositionSeconds = position
            record.watchedFraction = fraction
            record.lastWatchedAt = Date()
            try? modelContext.save()
        }
    }
}

extension View {
    func watchHistoryTracking() -> some View {
        modifier(WatchHistoryTracking())
    }
}
