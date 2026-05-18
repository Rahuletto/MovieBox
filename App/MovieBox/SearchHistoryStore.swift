import CoreStorage
import Foundation
import SwiftData

@MainActor
enum SearchHistoryStore {
  private static let minimumQueryLength = 2

  static func save(query: String, in modelContext: ModelContext) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= minimumQueryLength else { return }

    let fetchDescriptor = FetchDescriptor<SearchHistoryRecord>(
      predicate: #Predicate { $0.query == trimmed }
    )
    if let existing = try? modelContext.fetch(fetchDescriptor).first {
      existing.searchedAt = Date()
    } else {
      modelContext.insert(SearchHistoryRecord(query: trimmed))
    }
    try? modelContext.save()
  }
}
