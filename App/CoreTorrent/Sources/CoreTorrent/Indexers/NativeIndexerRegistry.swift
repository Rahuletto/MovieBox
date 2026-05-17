import Foundation

/// Runs all built-in Swift indexers in parallel.
public actor NativeIndexerRegistry {
    public static let defaultIndexers: [String] = ["yts", "eztv", "piratebay"]

    private let indexers: [any TorrentIndexer]

    public init(indexers: [any TorrentIndexer] = NativeIndexerRegistry.makeDefaultIndexers()) {
        self.indexers = indexers
    }

    public static func makeDefaultIndexers() -> [any TorrentIndexer] {
        [
            YTSIndexer(),
            EZTVIndexer(),
            PirateBayIndexer(),
        ]
    }

    public func search(
        context: TorrentSearchContext,
        enabledIDs: Set<String>? = nil
    ) async -> (results: [TorrentResult], errors: [String: String], counts: [String: Int]) {
        let active = indexers.filter { indexer in
            guard enabledIDs == nil || enabledIDs?.contains(indexer.id) == true else { return false }
            return indexer.supportedKinds.contains(context.kind)
        }

        var merged: [TorrentResult] = []
        var errors: [String: String] = [:]
        var counts: [String: Int] = [:]

        await withTaskGroup(of: (String, Result<[TorrentResult], Error>).self) { group in
            for indexer in active {
                let id = indexer.id
                group.addTask {
                    do {
                        let results = try await indexer.search(context: context)
                        return (id, .success(results))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }

            for await (id, result) in group {
                switch result {
                case .success(let rows):
                    counts[id] = rows.count
                    merged.append(contentsOf: rows)
                case .failure(let error):
                    errors[id] = error.localizedDescription
                    counts[id] = 0
                    NSLog("Native indexer \(id) failed: \(error)")
                }
            }
        }

        return (merged, errors, counts)
    }
}
