import Foundation

/// Direct apibay.org search from the Mac when the Cloudflare Worker cannot reach TPB mirrors.
public actor PirateBayClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func search(query: String) async throws -> [TorrentResult] {
        let hosts = ["apibay.org", "apibay.party", "apibay.rocks"]
        var lastError: Error?

        for host in hosts {
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = "/q.php"
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "cat", value: "200"),
            ]
            guard let url = components.url else { continue }

            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                request.setValue(
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                    forHTTPHeaderField: "User-Agent"
                )
                request.setValue("application/json", forHTTPHeaderField: "Accept")

                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }

                let rows = try JSONDecoder().decode([ApibayRow].self, from: data)
                let results: [TorrentResult] = rows.compactMap { row in
                    guard row.id != "0", !row.name.isEmpty else { return nil }
                    let hash = row.infoHash.lowercased()
                    guard hash.count == 40 else { return nil }
                    let title = row.name
                    return TorrentResult(
                        title: title,
                        magnetURI: Self.magnet(hash: hash, title: title),
                        quality: ReleaseParser.parseQuality(from: title),
                        hdrType: ReleaseParser.parseHDR(from: title),
                        codec: ReleaseParser.parseCodec(from: title),
                        audioFormat: ReleaseParser.parseAudio(from: title),
                        source: ReleaseParser.parseSource(from: title),
                        sizeBytes: Int64(row.size) ?? 0,
                        seeders: Int(row.seeders) ?? 0,
                        leechers: Int(row.leechers) ?? 0,
                        trackerSource: .native(site: "Pirate Bay"),
                        infoHash: hash,
                        indexerId: "piratebay"
                    )
                }
                guard !results.isEmpty else { continue }
                return results
            } catch {
                lastError = error
            }
        }

        if let lastError { throw lastError }
        throw NSError(domain: "PirateBayClient", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "Pirate Bay API unreachable",
        ])
    }

    private static func magnet(hash: String, title: String) -> String {
        TorrentMagnet.build(infoHash: hash, displayName: title)
    }
}

private struct ApibayRow: Decodable {
    let id: String
    let name: String
    let infoHash: String
    let size: String
    let seeders: String
    let leechers: String

    enum CodingKeys: String, CodingKey {
        case id, name, size, seeders, leechers
        case infoHash = "info_hash"
    }
}
