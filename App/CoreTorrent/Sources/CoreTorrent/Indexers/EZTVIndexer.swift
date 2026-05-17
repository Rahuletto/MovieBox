import Foundation

/// EZTV — TV torrents via public JSON API.
public actor EZTVIndexer: TorrentIndexer {
    public let id = "eztv"
    public let displayName = "EZTV"
    public let supportedKinds: Set<TorrentioClient.MediaKind> = [.tv]

    private let session: URLSession
    private let decoder: JSONDecoder

    private let hosts = ["eztv.wf", "eztvx.to", "eztv.re"]

    public init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
    }

    public func search(context: TorrentSearchContext) async throws -> [TorrentResult] {
        guard supportedKinds.contains(context.kind) else { return [] }

        var lastError: Error?
        for host in hosts {
            do {
                if let imdb = normalizedIMDb(context.imdbId) {
                    if let results = try await fetch(host: host, imdbId: imdb) {
                        return results
                    }
                }
                if let results = try await fetch(host: host, query: context.query) {
                    return results
                }
            } catch {
                lastError = error
                NSLog("EZTV search failed on \(host): \(error)")
            }
        }

        if let lastError { throw lastError }
        return []
    }

    private func fetch(host: String, imdbId: String) async throws -> [TorrentResult]? {
        var components = URLComponents(string: "https://\(host)/api/get-torrents")
        components?.queryItems = [
            URLQueryItem(name: "imdb_id", value: imdbId),
            URLQueryItem(name: "limit", value: "100"),
        ]
        return try await fetch(url: components?.url)
    }

    private func fetch(host: String, query: String) async throws -> [TorrentResult]? {
        var components = URLComponents(string: "https://\(host)/api/get-torrents")
        components?.queryItems = [
            URLQueryItem(name: "search_term", value: query),
            URLQueryItem(name: "limit", value: "100"),
        ]
        return try await fetch(url: components?.url)
    }

    private func fetch(url: URL?) async throws -> [TorrentResult]? {
        guard let url else { return nil }
        let (data, response) = try await session.data(for: IndexerHTTP.request(url: url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }

        let payload = try decoder.decode(EZTVResponse.self, from: data)
        guard let torrents = payload.torrents, !torrents.isEmpty else { return nil }

        return torrents.compactMap { row in
            let title = row.title ?? row.filename ?? "Unknown"
            let hash = (row.infoHash ?? row.hash ?? "").lowercased()
            guard !hash.isEmpty else { return nil }

            let magnet = row.magnetURL?.isEmpty == false
                ? row.magnetURL!
                : TorrentMagnet.build(infoHash: hash, title: title)

            return TorrentResult(
                title: title,
                magnetURI: magnet,
                quality: ReleaseParser.parseQuality(from: title),
                hdrType: ReleaseParser.parseHDR(from: title),
                codec: ReleaseParser.parseCodec(from: title),
                audioFormat: ReleaseParser.parseAudio(from: title),
                source: ReleaseParser.parseSource(from: title),
                sizeBytes: row.sizeBytes ?? 0,
                seeders: row.seeds ?? 0,
                leechers: row.peers ?? 0,
                trackerSource: .native(site: displayName),
                infoHash: hash
            )
        }
    }

    private func normalizedIMDb(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if !value.hasPrefix("tt") { value = "tt\(value)" }
        return value
    }
}

private struct EZTVResponse: Decodable, Sendable {
    let torrents: [EZTVTorrent]?
}

private struct EZTVTorrent: Decodable, Sendable {
    let title: String?
    let filename: String?
    let hash: String?
    let infoHash: String?
    let magnetURL: String?
    let sizeBytes: Int64?
    let seeds: Int?
    let peers: Int?

    enum CodingKeys: String, CodingKey {
        case title, filename, hash
        case infoHash = "info_hash"
        case magnetURL = "magnet_url"
        case sizeBytes = "size_bytes"
        case seeds, peers
    }
}
