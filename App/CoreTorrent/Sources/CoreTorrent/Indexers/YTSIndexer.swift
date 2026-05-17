import Foundation

/// YTS movie indexer (official API mirrors).
public actor YTSIndexer: TorrentIndexer {
    public let id = "yts"
    public let displayName = "YTS"
    public let supportedKinds: Set<TorrentioClient.MediaKind> = [.movie]

    private let client: YTSClient

    public init(client: YTSClient = YTSClient()) {
        self.client = client
    }

    public func search(context: TorrentSearchContext) async throws -> [TorrentResult] {
        guard supportedKinds.contains(context.kind) else { return [] }
        return try await client.search(query: context.query)
    }
}
