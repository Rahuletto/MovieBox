import Foundation

public actor TorrentioClient {
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
    }

    public enum MediaKind: String, Sendable {
        case movie
        case tv
    }

    public func search(imdbId: String, kind: MediaKind = .movie) async throws -> [TorrentResult] {
        var cleanId = imdbId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return [] }
        
        if !cleanId.hasPrefix("tt") {
            cleanId = "tt\(cleanId)"
        }

        let mediaPath = kind == .tv ? "series" : "movie"
        let urlString = "https://torrentio.strem.fun/providers=yts,eztv,rarbg,1337x,kickass,thepiratebay,torrentproject,limetorrents,zooqle,tgx/stream/\(mediaPath)/\(cleanId).json"
        guard let url = URL(string: urlString) else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return []
            }

            struct TorrentioResponse: Decodable {
                let streams: [TorrentioStream]?
            }

            struct TorrentioStream: Decodable {
                let title: String
                let infoHash: String
            }

            let responseObj = try decoder.decode(TorrentioResponse.self, from: data)
            guard let streams = responseObj.streams else { return [] }

            return streams.compactMap { stream in
                let titleLines = stream.title.components(separatedBy: "\n")
                let detailsLine = titleLines.count > 1 ? titleLines[1] : stream.title
                let metadataLine = titleLines.count > 2 ? titleLines[2] : ""

                let quality = ReleaseParser.parseQuality(from: detailsLine)
                let hdrType = ReleaseParser.parseHDR(from: detailsLine)
                let codec = ReleaseParser.parseCodec(from: detailsLine)
                let audio = ReleaseParser.parseAudio(from: detailsLine)
                let source = ReleaseParser.parseSource(from: detailsLine)

                // Parse size bytes (e.g. "1.8 GB" or "850 MB")
                var sizeBytes: Int64 = 0
                if let sizeRange = detailsLine.range(of: #"\d+(\.\d+)?\s*(GB|MB)"#, options: .regularExpression) {
                    let sizeStr = String(detailsLine[sizeRange]).lowercased()
                    if sizeStr.contains("gb") {
                        if let valStr = sizeStr.replacingOccurrences(of: "gb", with: "").trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first,
                           let val = Double(valStr) {
                            sizeBytes = Int64(val * 1024 * 1024 * 1024)
                        }
                    } else if sizeStr.contains("mb") {
                        if let valStr = sizeStr.replacingOccurrences(of: "mb", with: "").trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first,
                           let val = Double(valStr) {
                            sizeBytes = Int64(val * 1024 * 1024)
                        }
                    }
                }

                // Parse seeders and leechers from emoji indicators (👤 and 👥)
                var seeders = 0
                var leechers = 0
                if let seedsRange = metadataLine.range(of: #"👤\s*\d+"#, options: .regularExpression) {
                    let valStr = String(metadataLine[seedsRange]).replacingOccurrences(of: "👤", with: "").trimmingCharacters(in: .whitespaces)
                    seeders = Int(valStr) ?? 0
                }
                if let peersRange = metadataLine.range(of: #"👥\s*\d+"#, options: .regularExpression) {
                    let valStr = String(metadataLine[peersRange]).replacingOccurrences(of: "👥", with: "").trimmingCharacters(in: .whitespaces)
                    leechers = Int(valStr) ?? 0
                }

                // Fallback seeders extraction
                if seeders == 0 {
                    if let sRange = stream.title.range(of: #"S:\s*\d+"#, options: .regularExpression) {
                        let valStr = String(stream.title[sRange]).replacingOccurrences(of: "S:", with: "").trimmingCharacters(in: .whitespaces)
                        seeders = Int(valStr) ?? 0
                    }
                }

                let movieTitle = titleLines.first ?? "Unknown Movie"
                let magnet = TorrentMagnet.build(infoHash: stream.infoHash, displayName: movieTitle)

                return TorrentResult(
                    title: movieTitle,
                    magnetURI: magnet,
                    quality: quality,
                    hdrType: hdrType,
                    codec: codec,
                    audioFormat: audio,
                    source: source,
                    sizeBytes: sizeBytes,
                    seeders: seeders,
                    leechers: leechers,
                    trackerSource: .torrentio,
                    infoHash: stream.infoHash
                )
            }
        } catch {
            NSLog("Torrentio search error: \(error)")
            return []
        }
    }
}
