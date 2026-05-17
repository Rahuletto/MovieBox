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

public enum TorrentIndexerPreferences {
    public static let defaultIDs: Set<String> = ["torrentio", "yts", "eztv", "piratebay", "1337x"]

    public static func parseCSV(_ raw: String) -> Set<String> {
        let ids = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let known = defaultIDs
        let filtered = Set(ids.filter { known.contains($0) })
        return filtered.isEmpty ? defaultIDs : filtered
    }

    public static func serialize(_ ids: Set<String>) -> String {
        defaultIDs.filter { ids.contains($0) }.joined(separator: ",")
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

    public func fetchCatalog() async throws -> [TorrentIndexerCatalogEntry] {
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
        return payload.indexers.map {
            TorrentIndexerCatalogEntry(
                id: $0.id,
                name: $0.name,
                description: $0.description,
                kinds: $0.kinds
            )
        }
    }
}

private struct BackendConfigResponse: Decodable {
    let indexers: [BackendIndexerRow]
}

private struct BackendIndexerRow: Decodable {
    let id: String
    let name: String
    let description: String
    let kinds: [String]
}
