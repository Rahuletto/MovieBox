import Foundation

public struct TorrentSearchContext: Sendable {
    public let query: String
    public let year: Int?
    public let imdbId: String?
    public let kind: TorrentioClient.MediaKind

    public init(query: String, year: Int?, imdbId: String?, kind: TorrentioClient.MediaKind) {
        self.query = query
        self.year = year
        self.imdbId = imdbId
        self.kind = kind
    }
}

/// A built-in Swift torrent site indexer (no Jackett / sidecar).
public protocol TorrentIndexer: Sendable {
    var id: String { get }
    var displayName: String { get }
    var supportedKinds: Set<TorrentioClient.MediaKind> { get }

    func search(context: TorrentSearchContext) async throws -> [TorrentResult]
}

public enum TorrentMagnet {
    public static func build(infoHash: String, title: String) -> String {
        let hash = infoHash
            .replacingOccurrences(of: "urn:btih:", with: "", options: .caseInsensitive)
            .lowercased()
        let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        return "magnet:?xt=urn:btih:\(hash)&dn=\(encoded)"
    }
}

enum IndexerHTTP {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    static func request(url: URL, timeout: TimeInterval = 20) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
}
