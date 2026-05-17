import Foundation

/// Single backend call for all torrent sources (Torrentio + indexers). Indexer logic lives on the Worker.
public actor BackendTorrentSearcher {
    private let baseURL: URL
    private let appToken: String
    private let session: URLSession

    public init(baseURL: URL, appToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.appToken = appToken
        self.session = session
    }

    public struct SearchResponse: Sendable {
        public let results: [TorrentResult]
        public let diagnostics: TorrentSearchDiagnostics
        public let apiVersion: Int
    }

    public func search(
        query: String,
        year: Int?,
        imdbId: String?,
        kind: TorrentioClient.MediaKind,
        enabledIndexerIDs: Set<String>
    ) async throws -> SearchResponse {
        var components = URLComponents(url: baseURL.appending(path: "api/torrent/search"), resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "kind", value: kind.rawValue),
            URLQueryItem(name: "enabled", value: TorrentIndexerPreferences.serialize(enabledIndexerIDs)),
        ]
        if let year { items.append(URLQueryItem(name: "year", value: String(year))) }
        if let imdbId, !imdbId.isEmpty { items.append(URLQueryItem(name: "imdbId", value: imdbId)) }
        components?.queryItems = items
        guard let url = components?.url else {
            return SearchResponse(results: [], diagnostics: TorrentSearchDiagnostics(), apiVersion: 0)
        }

        var request = URLRequest(url: url)
        request.setValue(appToken, forHTTPHeaderField: "X-MovieBox-Token")
        request.timeoutInterval = 45

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "BackendTorrentSearcher", code: code, userInfo: [
                NSLocalizedDescriptionKey: "Backend torrent search failed (HTTP \(code))",
            ])
        }

        let payload = try JSONDecoder().decode(BackendTorrentSearchResponse.self, from: data)
        var diagnostics = TorrentSearchDiagnostics()
        diagnostics.queryUsed = payload.query ?? query
        diagnostics.torrentioAttempted = payload.torrentio?.attempted ?? false
        diagnostics.torrentioCount = payload.torrentio?.count ?? payload.counts?["torrentio"] ?? 0
        diagnostics.torrentioError = payload.torrentio?.error
        diagnostics.nativeCounts = payload.counts ?? [:]
        diagnostics.nativeErrors = payload.errors ?? [:]
        diagnostics.ytsCount = payload.counts?["yts"] ?? 0
        diagnostics.ytsAttempted = enabledIndexerIDs.contains("yts") && kind == .movie

        let results = payload.results.map { $0.torrentResult }
        return SearchResponse(
            results: results,
            diagnostics: diagnostics,
            apiVersion: payload.apiVersion ?? 0
        )
    }
}

private struct BackendTorrentSearchResponse: Decodable, Sendable {
    let results: [BackendTorrentHit]
    let counts: [String: Int]?
    let errors: [String: String]?
    let query: String?
    let torrentio: BackendTorrentioMeta?
    let apiVersion: Int?
}

private struct BackendTorrentioMeta: Decodable, Sendable {
    let attempted: Bool?
    let count: Int?
    let error: String?
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
        let source: TrackerSource
        if trackerSource.lowercased() == "torrentio" {
            source = .torrentio
        } else {
            source = .native(site: trackerSource)
        }

        return TorrentResult(
            title: title,
            magnetURI: magnetURI,
            quality: ReleaseParser.resolveQuality(indexerLabel: quality, title: title),
            hdrType: ReleaseParser.parseHDR(from: title),
            codec: ReleaseParser.parseCodec(from: title),
            audioFormat: ReleaseParser.parseAudio(from: title),
            source: ReleaseParser.parseSource(from: title),
            sizeBytes: sizeBytes ?? 0,
            seeders: seeders ?? 0,
            leechers: leechers ?? 0,
            trackerSource: source,
            infoHash: infoHash
        )
    }
}
