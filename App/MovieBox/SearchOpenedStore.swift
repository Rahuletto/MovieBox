import CoreMetadata
import CoreStorage
import Foundation
import SwiftData

@MainActor
enum SearchOpenedStore {
    private static let maxStoredItems = 48

    static func save(
        movie: Movie,
        kind: MediaKind,
        query: String,
        in modelContext: ModelContext
    ) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.count >= 2 else { return }

        let recordID = SearchOpenedRecord.makeRecordID(tmdbId: movie.id, mediaKind: kind.rawValue)
        let fetchDescriptor = FetchDescriptor<SearchOpenedRecord>(
            predicate: #Predicate { $0.recordID == recordID }
        )

        if let existing = try? modelContext.fetch(fetchDescriptor).first {
            existing.title = movie.title
            existing.posterPath = movie.posterPath
            existing.backdropPath = movie.backdropPath
            existing.searchQuery = trimmedQuery
            existing.openedAt = Date()
        } else {
            modelContext.insert(
                SearchOpenedRecord(
                    tmdbId: movie.id,
                    mediaKind: kind.rawValue,
                    title: movie.title,
                    posterPath: movie.posterPath,
                    backdropPath: movie.backdropPath,
                    searchQuery: trimmedQuery
                )
            )
        }

        try? modelContext.save()
        pruneOldRecords(in: modelContext)
    }

    private static func pruneOldRecords(in modelContext: ModelContext) {
        let descriptor = FetchDescriptor<SearchOpenedRecord>(
            sortBy: [SortDescriptor(\SearchOpenedRecord.openedAt, order: .reverse)]
        )
        guard let records = try? modelContext.fetch(descriptor), records.count > maxStoredItems else {
            return
        }
        for record in records.dropFirst(maxStoredItems) {
            modelContext.delete(record)
        }
        try? modelContext.save()
    }
}
