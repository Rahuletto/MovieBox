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
                let movieTitle = titleLines.first ?? "Unknown Title"
                
                // Join the non-metadata lines to parse release features (quality, HDR, codec, source, audio).
                // Usually the last line is the metadata line (which starts with 👤 or contains 💾).
                let releaseInfoStr = titleLines.count > 1 ? titleLines.dropLast().joined(separator: " ") : stream.title

                let quality = ReleaseParser.parseQuality(from: releaseInfoStr)
                let hdrType = ReleaseParser.parseHDR(from: releaseInfoStr)
                let codec = ReleaseParser.parseCodec(from: releaseInfoStr)
                let audio = ReleaseParser.parseAudio(from: releaseInfoStr)
                let source = ReleaseParser.parseSource(from: releaseInfoStr)

                // Parse size bytes from the ENTIRE stream.title (extremely robust!)
                var sizeBytes: Int64 = 0
                if let sizeRange = stream.title.range(of: #"\d+(\.\d+)?\s*(GB|MB)"#, options: .regularExpression) {
                    let sizeStr = String(stream.title[sizeRange]).lowercased()
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

                // Parse seeders and leechers from the ENTIRE stream.title
                var seeders = 0
                var leechers = 0
                if let seedsRange = stream.title.range(of: #"👤\s*\d+"#, options: .regularExpression) {
                    let valStr = String(stream.title[seedsRange]).replacingOccurrences(of: "👤", with: "").trimmingCharacters(in: .whitespaces)
                    seeders = Int(valStr) ?? 0
                }
                if let peersRange = stream.title.range(of: #"👥\s*\d+"#, options: .regularExpression) {
                    let valStr = String(stream.title[peersRange]).replacingOccurrences(of: "👥", with: "").trimmingCharacters(in: .whitespaces)
                    leechers = Int(valStr) ?? 0
                }

                // Fallback seeders extraction from S: or similar in full stream.title
                if seeders == 0 {
                    if let sRange = stream.title.range(of: #"S:\s*\d+"#, options: .regularExpression) {
                        let valStr = String(stream.title[sRange]).replacingOccurrences(of: "S:", with: "").trimmingCharacters(in: .whitespaces)
                        seeders = Int(valStr) ?? 0
                    }
                }

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
