import Foundation

/// The Pirate Bay via the community apibay JSON mirror.
public actor PirateBayIndexer: TorrentIndexer {
    public let id = "piratebay"
    public let displayName = "Pirate Bay"
    public let supportedKinds: Set<TorrentioClient.MediaKind> = [.movie, .tv]

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func search(context: TorrentSearchContext) async throws -> [TorrentResult] {
        var components = URLComponents(string: "https://apibay.org/q.php")
        components?.queryItems = [
            URLQueryItem(name: "q", value: context.query),
            URLQueryItem(name: "cat", value: categoryCode(for: context.kind)),
        ]
        guard let url = components?.url else { return [] }

        let (data, response) = try await session.data(for: IndexerHTTP.request(url: url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }

        let rows = try JSONDecoder().decode([PirateBayRow].self, from: data)
        return rows.compactMap { row in
            guard row.id != "0", let name = row.name, !name.isEmpty else { return nil }
            let hash = row.infoHash?.lowercased() ?? ""
            guard hash.count == 40 else { return nil }

            let magnet = TorrentMagnet.build(infoHash: hash, title: name)
            let size = Int64(row.size ?? "0") ?? 0
            let seeders = Int(row.seeders ?? "0") ?? 0
            let leechers = Int(row.leechers ?? "0") ?? 0

            return TorrentResult(
                title: name,
                magnetURI: magnet,
                quality: ReleaseParser.parseQuality(from: name),
                hdrType: ReleaseParser.parseHDR(from: name),
                codec: ReleaseParser.parseCodec(from: name),
                audioFormat: ReleaseParser.parseAudio(from: name),
                source: ReleaseParser.parseSource(from: name),
                sizeBytes: size,
                seeders: seeders,
                leechers: leechers,
                trackerSource: .native(site: displayName),
                infoHash: hash
            )
        }
    }

    private func categoryCode(for kind: TorrentioClient.MediaKind) -> String {
        switch kind {
        case .movie: "207" // HD Movies
        case .tv: "205" // TV shows
        }
    }
}

private struct PirateBayRow: Decodable, Sendable {
    let id: String
    let name: String?
    let infoHash: String?
    let size: String?
    let seeders: String?
    let leechers: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case infoHash = "info_hash"
        case size, seeders, leechers
    }
}
