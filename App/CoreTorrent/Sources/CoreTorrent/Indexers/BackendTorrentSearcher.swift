import Foundation

/// Proxies built-in indexer searches through the MovieBox backend (Cloudflare Worker).
public actor BackendTorrentSearcher {
    private let baseURL: URL
    private let appToken: String
    private let session: URLSession

    public init(baseURL: URL, appToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.appToken = appToken
        self.session = session
    }

    public func search(
        query: String,
        year: Int?,
        imdbId: String?,
        kind: TorrentioClient.MediaKind,
        enableYTS: Bool
    ) async throws -> (results: [TorrentResult], counts: [String: Int], errors: [String: String]) {
        var components = URLComponents(url: baseURL.appending(path: "api/torrent/search"), resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "kind", value: kind.rawValue),
            URLQueryItem(name: "enableYTS", value: enableYTS ? "1" : "0"),
        ]
        if let year { items.append(URLQueryItem(name: "year", value: String(year))) }
        if let imdbId, !imdbId.isEmpty { items.append(URLQueryItem(name: "imdbId", value: imdbId)) }
        components?.queryItems = items
        guard let url = components?.url else { return ([], [:], [:]) }

        var request = URLRequest(url: url)
        request.setValue(appToken, forHTTPHeaderField: "X-MovieBox-Token")
        request.timeoutInterval = 25

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "BackendTorrentSearcher", code: code, userInfo: [
                NSLocalizedDescriptionKey: "Backend torrent search failed (HTTP \(code))",
            ])
        }

        let payload = try JSONDecoder().decode(BackendTorrentSearchResponse.self, from: data)
        let mapped = payload.results.map { $0.torrentResult }
        return (mapped, payload.counts ?? [:], payload.errors ?? [:])
    }
}

private struct BackendTorrentSearchResponse: Decodable, Sendable {
    let results: [BackendTorrentHit]
    let counts: [String: Int]?
    let errors: [String: String]?
}

private struct BackendTorrentHit: Decodable, Sendable {
    let title: String
    let magnetURI: String
    let infoHash: String?
    let quality: String?
    let sizeBytes: Int64?
    let seeders: Int?
    let leechers: Int?
    let trackerSource: String

    var torrentResult: TorrentResult {
        TorrentResult(
            title: title,
            magnetURI: magnetURI,
            quality: ReleaseParser.parseQuality(from: title),
            hdrType: ReleaseParser.parseHDR(from: title),
            codec: ReleaseParser.parseCodec(from: title),
            audioFormat: ReleaseParser.parseAudio(from: title),
            source: ReleaseParser.parseSource(from: title),
            sizeBytes: sizeBytes ?? 0,
            seeders: seeders ?? 0,
            leechers: leechers ?? 0,
            trackerSource: .native(site: trackerSource),
            infoHash: infoHash
        )
    }
}
