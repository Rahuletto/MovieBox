import CoreMetadata
import CoreStorage
import MovieBoxCore
import SwiftData
import SwiftUI

enum WatchProgressStore {
    @MainActor
    @discardableResult
    static func ensureRecord(
        movie: Movie,
        kind: MediaKind,
        genres: [Int],
        in context: ModelContext,
        existing: [MovieRecord]
    ) -> MovieRecord {
        if let record = existing.first(where: { $0.tmdbId == movie.id }) {
            if record.title.isEmpty {
                record.title = movie.title
            }
            if record.posterPath == nil {
                record.posterPath = movie.posterPath
            }
            return record
        }

        let record = MovieRecord(
            tmdbId: movie.id,
            mediaKind: kind.storageValue,
            title: movie.title,
            posterPath: movie.posterPath,
            genres: genres,
            lastWatchedAt: Date()
        )
        context.insert(record)
        try? context.save()
        return record
    }

    static func savedPosition(for tmdbId: Int, in records: [MovieRecord]) -> Double {
        records.first(where: { $0.tmdbId == tmdbId })?.playbackPositionSeconds ?? 0
    }

    static func resumePosition(for tmdbId: Int, in records: [MovieRecord]) -> Double? {
        let position = savedPosition(for: tmdbId, in: records)
        return PlaybackDisplayTitle.hasContinueProgress(positionSeconds: position)
            ? position
            : nil
    }

    static func effectiveDuration(for record: MovieRecord) -> Double {
        if record.durationSeconds > 0 { return record.durationSeconds }
        if record.watchedFraction > 0.01 {
            return record.playbackPositionSeconds / record.watchedFraction
        }
        return 0
    }

    /// Progress 0…1 for UI; prefers position ÷ stored duration.
    static func progressFraction(for record: MovieRecord) -> Double {
        let duration = effectiveDuration(for: record)
        if duration > 0 {
            return min(1, max(0, record.playbackPositionSeconds / duration))
        }
        return min(1, max(0, record.watchedFraction))
    }

    /// e.g. `17m left`, `1hr left`, `1hr 27m left`
    static func timeRemainingLabel(for record: MovieRecord) -> String? {
        let duration = effectiveDuration(for: record)
        guard duration > record.playbackPositionSeconds else { return nil }
        let remaining = Int(ceil(duration - record.playbackPositionSeconds))
        guard remaining > 0 else { return nil }

        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60

        if hours > 0 {
            if minutes > 0 {
                return "\(hours)hr \(minutes)m left"
            }
            return "\(hours)hr left"
        }
        if minutes > 0 {
            return "\(minutes)m left"
        }
        return "<1m left"
    }
}
