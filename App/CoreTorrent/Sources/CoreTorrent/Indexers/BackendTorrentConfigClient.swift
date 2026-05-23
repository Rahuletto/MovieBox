import Foundation

public struct TorrentIndexerCatalogEntry: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let description: String
    public let kinds: [String]

    public init(id: String, name: String, description: String, kinds: [String]) {
        self.id = id
        self.name = name
        self.description = description
        self.kinds = kinds
    }
}

public struct BackendTorrentConfig: Sendable {
    public let indexers: [TorrentIndexerCatalogEntry]
    public let defaultEnabledIndexerIDs: [String]

    public init(indexers: [TorrentIndexerCatalogEntry], defaultEnabledIndexerIDs: [String]) {
        self.indexers = indexers
        self.defaultEnabledIndexerIDs = defaultEnabledIndexerIDs
    }
}

public enum TorrentIndexerPreferences {
    /// Legacy fallback when the backend catalog is unavailable.
    public static let defaultIDs: Set<String> = ["torrentio", "yts", "eztv", "piratebay", "1337x"]

    /// Parses a comma-separated indexer list. An empty string means all disabled.
    /// When `knownIDs` is provided, unknown ids are dropped (stale entries after catalog changes).
    public static func parseCSV(_ raw: String, knownIDs: Set<String>? = nil) -> Set<String> {
        let ids = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let parsed = Set(ids)
        guard let knownIDs, !knownIDs.isEmpty else { return parsed }
        return Set(parsed.filter { knownIDs.contains($0) })
    }

    /// Serializes enabled ids. Pass `order` (e.g. backend catalog order) for stable CSV.
    public static func serialize(_ ids: Set<String>, order: [String]? = nil) -> String {
        guard !ids.isEmpty else { return "" }
        if let order, !order.isEmpty {
            return order.filter { ids.contains($0) }.joined(separator: ",")
        }
        return ids.sorted().joined(separator: ",")
    }

    /// Keeps rows whose indexer is enabled in Settings (backend returns all indexers).
    public static func filter(_ results: [TorrentResult], enabledIDs: Set<String>) -> [TorrentResult] {
        guard !enabledIDs.isEmpty else { return [] }
        return results.filter { torrent in
            guard let id = torrent.indexerId ?? indexerId(for: torrent.trackerSource) else { return true }
            return enabledIDs.contains(id)
        }
    }

    /// Maps API `trackerSource` labels to catalog indexer ids.
    public static func indexerId(for source: TrackerSource) -> String? {
        switch source {
        case .yts: "yts"
        case .torrentio: "torrentio"
        case .native(let site):
            switch site.lowercased() {
            case "pirate bay": "piratebay"
            case "1337x": "1337x"
            case "eztv": "eztv"
            case "nyaa": "nyaa"
            case "limetorrents": "limetorrents"
            case "torrentgalaxy": "torrentgalaxy"
            case "magnetdl": "magnetdl"
            case "solid torrents": "solidtorrents"
            case "rutracker": "rutracker"
            case "kickasstorrents": "kickasstorrents"
            case "rarbg": "rarbg"
            case "zooqle": "zooqle"
            case "torrentfunk": "torrentfunk"
            case "isohunt": "isohunt"
            case "torrent download": "torrentdownload"
            case "bitsearch": "bitsearch"
            default: nil
            }
        case .torrentAPI: nil
        }
    }
}

public actor BackendTorrentConfigClient {
    private let baseURL: URL
    private let appToken: String
    private let session: URLSession

    public init(baseURL: URL, appToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.appToken = appToken
        self.session = session
    }

    public func fetchCatalog() async throws -> BackendTorrentConfig {
        let url = baseURL.appending(path: "api/config")
        var request = URLRequest(url: url)
        request.setValue(appToken, forHTTPHeaderField: "X-MovieBox-Token")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "BackendTorrentConfigClient", code: code, userInfo: [
                NSLocalizedDescriptionKey: "Backend config failed (HTTP \(code))",
            ])
        }

        let payload = try JSONDecoder().decode(BackendConfigResponse.self, from: data)
        let indexers = payload.indexers.map {
            TorrentIndexerCatalogEntry(
                id: $0.id,
                name: $0.name,
                description: $0.description,
                kinds: $0.kinds
            )
        }
        return BackendTorrentConfig(
            indexers: indexers,
            defaultEnabledIndexerIDs: payload.defaultEnabledIndexers
        )
    }
}

private struct BackendConfigResponse: Decodable {
    let indexers: [BackendIndexerRow]
    let defaultEnabledIndexers: [String]
}

private struct BackendIndexerRow: Decodable {
    let id: String
    let name: String
    let description: String
    let kinds: [String]
}
