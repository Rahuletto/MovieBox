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

    /// Ensures a `MovieRecord` exists so local/download playback can persist resume position.
    @MainActor
    @discardableResult
    static func ensurePlaybackRecord(
        tmdbId: Int,
        title: String,
        mediaKind: MediaKind,
        posterPath: String? = nil,
        in context: ModelContext,
        existing: [MovieRecord]
    ) -> MovieRecord? {
        guard tmdbId > 0 else { return nil }
        let cleanedTitle = PlaybackDisplayTitle.clean(title)
        if let record = existing.first(where: { $0.tmdbId == tmdbId }) {
            if record.title.isEmpty {
                record.title = cleanedTitle
            }
            if record.posterPath == nil, let posterPath {
                record.posterPath = posterPath
            }
            return record
        }
        let record = MovieRecord(
            tmdbId: tmdbId,
            mediaKind: mediaKind.storageValue,
            title: cleanedTitle,
            posterPath: posterPath,
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

    /// Remaining runtime for overlays, e.g. `47m`, `1h 27m`.
    static func remainingTimeLabel(for record: MovieRecord) -> String? {
        let duration = effectiveDuration(for: record)
        guard duration > record.playbackPositionSeconds else { return nil }
        let remaining = Int(ceil(duration - record.playbackPositionSeconds))
        guard remaining > 0 else { return nil }

        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60

        if hours > 0 {
            if minutes > 0 {
                return "\(hours)h \(minutes)m"
            }
            return "\(hours)h"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return "<1m"
    }

    /// Apple TV–style chip: `S1, E1 • 47m` for series, `31m` for movies.
    static func continueWatchingOverlayLabel(for record: MovieRecord) -> String? {
        guard let time = remainingTimeLabel(for: record) else { return nil }
        if record.mediaKindEnum == .tv,
           record.lastWatchedSeason > 0,
           record.lastWatchedEpisode > 0 {
            return "S\(record.lastWatchedSeason), E\(record.lastWatchedEpisode) • \(time)"
        }
        return time
    }

    /// Legacy subtitle under poster rows.
    static func timeRemainingLabel(for record: MovieRecord) -> String? {
        guard let label = remainingTimeLabel(for: record) else { return nil }
        return "\(label) left"
    }
}
