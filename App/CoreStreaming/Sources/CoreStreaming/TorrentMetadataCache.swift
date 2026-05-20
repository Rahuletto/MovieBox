import Foundation

/// In-memory cache so playback and prewarm reuse the same resolved `TorrentMetadata`.
actor TorrentMetadataCache {
    static let shared = TorrentMetadataCache()

    private var entries: [String: TorrentMetadata] = [:]
    private var inFlight: [String: Task<TorrentMetadata, Error>] = [:]

    func cached(infoHash: String) -> TorrentMetadata? {
        entries[infoHash.lowercased()]
    }

    func fetch(
        infoHash: String,
        magnetTrackers: [String],
        loader: @Sendable @escaping () async throws -> TorrentMetadata
    ) async throws -> TorrentMetadata {
        let key = infoHash.lowercased()
        if let hit = entries[key] {
            return hit
        }

        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task.detached(priority: .userInitiated) {
            try await loader()
        }
        inFlight[key] = task

        do {
            let metadata = try await task.value
            entries[key] = metadata
            inFlight[key] = nil
            return metadata
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    func remove(infoHash: String) {
        let key = infoHash.lowercased()
        entries[key] = nil
        inFlight[key]?.cancel()
        inFlight[key] = nil
    }
}
