import Foundation

public enum VideoQuality: String, Sendable, Codable, CaseIterable, Comparable {
    case p720 = "720p"
    case p1080 = "1080p"
    case p2160 = "4K"

    private var rank: Int {
        switch self {
        case .p720: 0
        case .p1080: 1
        case .p2160: 2
        }
    }

    public static func < (lhs: VideoQuality, rhs: VideoQuality) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum HDRType: String, Sendable, Codable {
    case dolbyVisionWithHDR10 = "DV/HDR10"
    case dolbyVisionOnly = "Dolby Vision"
    case hdr10Plus = "HDR10+"
    case hdr10 = "HDR10"
    case hdr = "HDR"
    case hlg = "HLG"
}

public enum HDRConfidence: String, Sendable, Codable {
    case fromFilename
    case fromMetadata
}

public enum VideoCodec: String, Sendable, Codable {
    case h264 = "H.264"
    case h265 = "H.265"
    case av1 = "AV1"
}

public enum AudioFormat: String, Sendable, Codable {
    case dolbyAtmos = "Atmos"
    case dtsX = "DTS:X"
    case truehd = "TrueHD"
    case dtshd = "DTS-HD"
    case eac3 = "EAC3"
    case aac = "AAC"
}

public enum VideoSource: String, Sendable, Codable {
    case bluray = "BluRay"
    case webdl = "WEB-DL"
    case webrip = "WEBRip"
    case hdcam = "HDCAM"
    case unknown = "Unknown"
}

public enum TrackerSource: Sendable, Codable, Hashable {
    case yts
    case native(site: String)
    case torrentAPI
    case torrentio

    public var label: String {
        switch self {
        case .yts: "YTS"
        case .native(let site): site
        case .torrentAPI: "Torrent API"
        case .torrentio: "Torrentio"
        }
    }
}

public struct TorrentResult: Identifiable, Sendable, Codable, Hashable {
    public let id: UUID
    public let title: String
    public let magnetURI: String
    public let quality: VideoQuality
    public let hdrType: HDRType?
    public let hdrConfidence: HDRConfidence
    public let codec: VideoCodec
    public let audioFormat: AudioFormat?
    public let source: VideoSource
    public let sizeBytes: Int64
    public let seeders: Int
    public let leechers: Int
    public let uploadDate: Date
    public let trackerSource: TrackerSource
    public let infoHash: String?
    public let language: String
    /// Backend indexer id (`piratebay`, `yts`, …) when known — used for Settings provider filter.
    public let indexerId: String?

    public init(
        id: UUID = UUID(),
        title: String,
        magnetURI: String,
        quality: VideoQuality,
        hdrType: HDRType?,
        hdrConfidence: HDRConfidence = .fromFilename,
        codec: VideoCodec,
        audioFormat: AudioFormat?,
        source: VideoSource,
        sizeBytes: Int64,
        seeders: Int,
        leechers: Int,
        uploadDate: Date = Date(),
        trackerSource: TrackerSource,
        infoHash: String? = nil,
        language: String? = nil,
        indexerId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.magnetURI = magnetURI
        self.quality = quality
        self.hdrType = hdrType
        self.hdrConfidence = hdrConfidence
        self.codec = codec
        self.audioFormat = audioFormat
        self.source = source
        self.sizeBytes = sizeBytes
        self.seeders = seeders
        self.leechers = leechers
        self.uploadDate = uploadDate
        self.trackerSource = trackerSource
        self.infoHash = infoHash
        self.language = language ?? ReleaseParser.parseLanguage(from: title)
        self.indexerId = indexerId
    }
}

extension TorrentResult {
    public var resolvedInfoHash: String? {
        if let infoHash = infoHash, !infoHash.isEmpty {
            return infoHash.lowercased()
        }
        guard magnetURI.lowercased().hasPrefix("magnet:?") else { return nil }
        let query = String(magnetURI.dropFirst(8))
        for pair in query.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let value = parts[1].removingPercentEncoding ?? parts[1]
            if key == "xt", value.lowercased().hasPrefix("urn:btih:") {
                return String(value.dropFirst(9)).lowercased()
            }
        }
        return nil
    }

    /// Builds a torrent row from a magnet link using filename/metadata parsing.
    public static func fromMagnetURI(_ magnetURI: String, fallbackTitle: String) -> TorrentResult? {
        guard magnetURI.lowercased().hasPrefix("magnet:?") else { return nil }

        var infoHash: String?
        var displayName = fallbackTitle

        let query = String(magnetURI.dropFirst(8))
        for pair in query.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let value = parts[1].removingPercentEncoding ?? parts[1]
            if key == "xt", value.lowercased().hasPrefix("urn:btih:") {
                infoHash = String(value.dropFirst(9)).lowercased()
            } else if key == "dn", !value.isEmpty {
                displayName = value
            }
        }

        let title = displayName
        return TorrentResult(
            title: title,
            magnetURI: magnetURI,
            quality: ReleaseParser.parseQuality(from: title),
            hdrType: ReleaseParser.parseHDR(from: title),
            codec: ReleaseParser.parseCodec(from: title),
            audioFormat: ReleaseParser.parseAudio(from: title),
            source: ReleaseParser.parseSource(from: title),
            sizeBytes: 0,
            seeders: 0,
            leechers: 0,
            trackerSource: .torrentio,
            infoHash: infoHash
        )
    }
}

public enum ReleaseParser {
    public static func parseHDR(from title: String) -> HDRType? {
        let t = normalized(title)
        if t.contains("dv") || t.contains("dovi") || t.contains("dolby vision") {
            if t.contains("hdr10") || t.contains("hdr") {
                return .dolbyVisionWithHDR10
            }
            return .dolbyVisionOnly
        }
        if t.contains("hdr10+") || t.contains("hdr10plus") { return .hdr10Plus }
        if t.contains("hdr10") { return .hdr10 }
        if tokenized(t).contains("hdr") { return .hdr }
        if tokenized(t).contains("hlg") { return .hlg }
        return nil
    }

    public static func parseCodec(from title: String) -> VideoCodec {
        let t = normalized(title)
        if tokenized(t).contains("av1") { return .av1 }
        if t.contains("x265") || t.contains("h265") || t.contains("hevc") { return .h265 }
        return .h264
    }

    public static func parseQuality(from title: String) -> VideoQuality {
        let t = normalized(title)
        if t.contains("2160") || tokenized(t).contains("4k") || tokenized(t).contains("uhd") { return .p2160 }
        if t.contains("1080") { return .p1080 }
        if t.contains("720") { return .p720 }
        return .p1080
    }

    /// Release title wins when it contains an explicit resolution; otherwise use the indexer label.
    public static func resolveQuality(indexerLabel: String?, title: String) -> VideoQuality {
        if titleHasExplicitResolution(title) {
            return parseQuality(from: title)
        }
        if let indexerLabel, !indexerLabel.isEmpty {
            return parseQuality(from: indexerLabel)
        }
        return parseQuality(from: title)
    }

    private static func titleHasExplicitResolution(_ title: String) -> Bool {
        let t = normalized(title)
        return t.contains("2160")
            || t.contains("1080")
            || t.contains("720")
            || tokenized(t).contains("4k")
            || tokenized(t).contains("uhd")
    }

    public static func parseAudio(from title: String) -> AudioFormat? {
        let t = normalized(title)
        if t.contains("atmos") { return .dolbyAtmos }
        if t.contains("dts x") || t.contains("dtsx") { return .dtsX }
        if t.contains("truehd") { return .truehd }
        if t.contains("dts hd") || t.contains("dtshd") { return .dtshd }
        if t.contains("eac3") || t.contains("e ac3") { return .eac3 }
        if tokenized(t).contains("aac") { return .aac }
        return nil
    }

    public static func parseSource(from title: String) -> VideoSource {
        let t = normalized(title)
        if t.contains("bluray") || t.contains("blu ray") { return .bluray }
        if t.contains("web dl") || t.contains("webdl") { return .webdl }
        if t.contains("webrip") || t.contains("web rip") { return .webrip }
        if t.contains("hdcam") || t.contains("camrip") { return .hdcam }
        return .unknown
    }

    public static func parseLanguage(from title: String) -> String {
        let t = normalized(title)

        if t.contains("multi") || t.contains("dual audio") || t.contains("dual-audio") {
            return "Multi"
        }

        let rules: [(String, String)] = [
            ("english", "English"), (" eng ", "English"), ("[eng]", "English"),
            ("french", "French"), ("fre", "French"), ("fra", "French"), ("[fre]", "French"),
            ("spanish", "Spanish"), ("spa", "Spanish"), ("[spa]", "Spanish"),
            ("german", "German"), ("ger", "German"), ("deu", "German"), ("[ger]", "German"),
            ("italian", "Italian"), ("ita", "Italian"), ("[ita]", "Italian"),
            ("portuguese", "Portuguese"), ("por", "Portuguese"), ("[por]", "Portuguese"),
            ("russian", "Russian"), ("rus", "Russian"), ("[rus]", "Russian"),
            ("japanese", "Japanese"), ("jpn", "Japanese"), ("[jpn]", "Japanese"),
            ("korean", "Korean"), ("kor", "Korean"), ("[kor]", "Korean"),
            ("hindi", "Hindi"), ("hin", "Hindi"),
            ("arabic", "Arabic"), ("ara", "Arabic"),
            ("polish", "Polish"), ("pol", "Polish"),
            ("dutch", "Dutch"), ("nld", "Dutch"),
            ("swedish", "Swedish"), ("swe", "Swedish"),
            ("danish", "Danish"), ("dan", "Danish"),
            ("norwegian", "Norwegian"), ("nor", "Norwegian"),
            ("finnish", "Finnish"), ("fin", "Finnish"),
            ("turkish", "Turkish"), ("tur", "Turkish"),
            ("greek", "Greek"), ("ell", "Greek"),
            ("czech", "Czech"), ("ces", "Czech"),
            ("hungarian", "Hungarian"), ("hun", "Hungarian"),
            ("romanian", "Romanian"), ("ron", "Romanian"),
            ("thai", "Thai"), ("tha", "Thai"),
            ("vietnamese", "Vietnamese"), ("vie", "Vietnamese"),
            ("chinese", "Chinese"), ("chi", "Chinese"), ("zho", "Chinese"),
        ]

        for (needle, label) in rules {
            if t.contains(needle) {
                return label
            }
        }

        if let regex = try? NSRegularExpression(pattern: #"\[([a-z]{2,3})\]"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let codeRange = Range(match.range(at: 1), in: t) {
            return String(t[codeRange]).uppercased()
        }

        return "Unknown"
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    private static func tokenized(_ value: String) -> Set<String> {
        Set(value.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "+" }).map(String.init))
    }
}

public struct TorrentSearchProgress: Sendable {
    public let torrents: [TorrentResult]
    public let diagnostics: TorrentSearchDiagnostics?
    public let isComplete: Bool

    public init(torrents: [TorrentResult], diagnostics: TorrentSearchDiagnostics?, isComplete: Bool) {
        self.torrents = torrents
        self.diagnostics = diagnostics
        self.isComplete = isComplete
    }
}

public actor TorrentSearchAggregator {
    private let backendSearcher: BackendTorrentSearcher?
    private let torrentioFallback: TorrentioClient
    private let pirateBayClient: PirateBayClient
    public private(set) var lastDiagnostics = TorrentSearchDiagnostics()

    public init(
        backendBaseURL: URL? = nil,
        backendAppToken: String? = nil,
        torrentioFallback: TorrentioClient = TorrentioClient(),
        pirateBayClient: PirateBayClient = PirateBayClient()
    ) {
        self.torrentioFallback = torrentioFallback
        self.pirateBayClient = pirateBayClient
        if let backendBaseURL, let backendAppToken, !backendAppToken.isEmpty {
            self.backendSearcher = BackendTorrentSearcher(baseURL: backendBaseURL, appToken: backendAppToken)
        } else {
            self.backendSearcher = nil
        }
    }

    public func search(
        movieTitle: String,
        year: Int? = nil,
        imdbId: String? = nil,
        kind: TorrentioClient.MediaKind = .movie,
        enabledIndexerIDs: Set<String> = TorrentIndexerPreferences.defaultIDs,
        queryOverride: String? = nil
    ) -> AsyncStream<TorrentSearchProgress> {
        return AsyncStream { continuation in
            Task {
                let query = queryOverride ?? TorrentSearchQuery.make(title: movieTitle, year: year)

                if let backendSearcher {
                    var batches: [[TorrentResult]] = []
                    let streamSucceeded = await consumeBackendStream(
                        backendSearcher: backendSearcher,
                        query: query,
                        year: year,
                        imdbId: imdbId,
                        kind: kind,
                        enabledIndexerIDs: enabledIndexerIDs,
                        batches: &batches,
                        continuation: continuation
                    )
                    if !streamSucceeded {
                        do {
                            let response = try await backendSearcher.search(
                                query: query,
                                year: year,
                                imdbId: imdbId,
                                kind: kind
                            )
                            var diagnostics = response.diagnostics
                            let supplemented = await supplementNativeIndexers(
                                results: response.results,
                                query: query,
                                imdbId: imdbId,
                                kind: kind,
                                diagnostics: &diagnostics,
                                enabledIDs: enabledIndexerIDs
                            )
                            lastDiagnostics = diagnostics
                            let filtered = Self.filterByEnabledIndexers(
                                Self.sorted(supplemented),
                                enabledIDs: enabledIndexerIDs
                            )
                            continuation.yield(TorrentSearchProgress(
                                torrents: filtered,
                                diagnostics: diagnostics,
                                isComplete: true
                            ))
                        } catch {
                            var diagnostics = TorrentSearchDiagnostics()
                            diagnostics.queryUsed = query
                            diagnostics.nativeErrors["backend"] = error.localizedDescription
                            lastDiagnostics = diagnostics
                            continuation.yield(TorrentSearchProgress(
                                torrents: [],
                                diagnostics: diagnostics,
                                isComplete: true
                            ))
                        }
                    }
                    continuation.finish()
                    return
                }

                var diagnostics = TorrentSearchDiagnostics()
                diagnostics.queryUsed = query
                diagnostics.nativeErrors["backend"] =
                    "Configure backend URL and app token in Settings for full search (YTS, 1337x, EZTV, …)."

                var results: [TorrentResult] = []
                if let imdb = imdbId, !imdb.isEmpty {
                    diagnostics.torrentioAttempted = true
                    do {
                        results = try await torrentioFallback.search(imdbId: imdb, kind: kind)
                        diagnostics.torrentioCount = results.count
                    } catch {
                        diagnostics.torrentioError = error.localizedDescription
                    }
                }

                lastDiagnostics = diagnostics
                let sorted = Self.sorted(results)
                continuation.yield(TorrentSearchProgress(
                    torrents: sorted,
                    diagnostics: diagnostics,
                    isComplete: true
                ))
                continuation.finish()
            }
        }
    }

    private func consumeBackendStream(
        backendSearcher: BackendTorrentSearcher,
        query: String,
        year: Int?,
        imdbId: String?,
        kind: TorrentioClient.MediaKind,
        enabledIndexerIDs: Set<String>,
        batches: inout [[TorrentResult]],
        continuation: AsyncStream<TorrentSearchProgress>.Continuation
    ) async -> Bool {
        do {
            for try await event in backendSearcher.searchStream(
                query: query,
                year: year,
                imdbId: imdbId,
                kind: kind
            ) {
                switch event {
                case .batch(_, let results):
                    let kept = Self.filterByEnabledIndexers(results, enabledIDs: enabledIndexerIDs)
                    guard !kept.isEmpty else { continue }
                    batches.append(kept)
                    let merged = Self.sorted(Self.merged(batches))
                    continuation.yield(TorrentSearchProgress(
                        torrents: merged,
                        diagnostics: nil,
                        isComplete: false
                    ))
                case .done(var diagnostics, _):
                    let supplemented = await supplementNativeIndexers(
                        results: Self.merged(batches),
                        query: query,
                        imdbId: imdbId,
                        kind: kind,
                        diagnostics: &diagnostics,
                        enabledIDs: enabledIndexerIDs
                    )
                    self.lastDiagnostics = diagnostics
                    let filtered = Self.filterByEnabledIndexers(
                        Self.sorted(supplemented),
                        enabledIDs: enabledIndexerIDs
                    )
                    continuation.yield(TorrentSearchProgress(
                        torrents: filtered,
                        diagnostics: diagnostics,
                        isComplete: true
                    ))
                    return true
                case .fatal(let message):
                    var diagnostics = TorrentSearchDiagnostics()
                    diagnostics.queryUsed = query
                    diagnostics.nativeErrors["backend"] = message
                    let supplemented = await supplementNativeIndexers(
                        results: Self.merged(batches),
                        query: query,
                        imdbId: imdbId,
                        kind: kind,
                        diagnostics: &diagnostics,
                        enabledIDs: enabledIndexerIDs
                    )
                    self.lastDiagnostics = diagnostics
                    let filtered = Self.filterByEnabledIndexers(
                        Self.sorted(supplemented),
                        enabledIDs: enabledIndexerIDs
                    )
                    continuation.yield(TorrentSearchProgress(
                        torrents: filtered,
                        diagnostics: diagnostics,
                        isComplete: true
                    ))
                    return true
                }
            }
            return !batches.isEmpty
        } catch {
            NSLog("Backend torrent SSE failed, falling back to batch search: \(error)")
            return false
        }
    }

    /// Cloudflare Workers often cannot reach apibay/Torrentio; fill gaps from the Mac directly.
    private func supplementNativeIndexers(
        results: [TorrentResult],
        query: String,
        imdbId: String?,
        kind: TorrentioClient.MediaKind,
        diagnostics: inout TorrentSearchDiagnostics,
        enabledIDs: Set<String>
    ) async -> [TorrentResult] {
        var merged = Self.mergedUnique(results)

        if enabledIDs.contains("piratebay") {
            let backendCount = diagnostics.nativeCounts["piratebay"] ?? 0
            let backendFailed = diagnostics.nativeErrors["piratebay"] != nil
            if backendCount == 0 || backendFailed {
                do {
                    let rows = try await pirateBayClient.search(query: query)
                    if !rows.isEmpty {
                        merged = Self.mergedUnique(merged + rows)
                        diagnostics.nativeCounts["piratebay"] = backendCount + rows.count
                        diagnostics.nativeErrors.removeValue(forKey: "piratebay")
                        NSLog("Native Pirate Bay supplement added \(rows.count) rows")
                    }
                } catch {
                    if diagnostics.nativeErrors["piratebay"] == nil {
                        diagnostics.nativeErrors["piratebay"] = error.localizedDescription
                    }
                    NSLog("Native Pirate Bay supplement failed: \(error.localizedDescription)")
                }
            }
        }

        if enabledIDs.contains("torrentio"), let imdbId, !imdbId.isEmpty {
            let backendFailed = diagnostics.torrentioError != nil
            if diagnostics.torrentioCount == 0 || backendFailed {
                diagnostics.torrentioAttempted = true
                do {
                    let rows = try await torrentioFallback.search(imdbId: imdbId, kind: kind)
                    if !rows.isEmpty {
                        merged = Self.mergedUnique(merged + rows)
                        diagnostics.torrentioCount += rows.count
                        diagnostics.torrentioError = nil
                        NSLog("Native Torrentio supplement added \(rows.count) rows")
                    }
                } catch {
                    if diagnostics.torrentioError == nil {
                        diagnostics.torrentioError = error.localizedDescription
                    }
                    NSLog("Native Torrentio supplement failed: \(error.localizedDescription)")
                }
            }
        }

        return merged
    }

    private static func merged(_ batches: [[TorrentResult]]) -> [TorrentResult] {
        mergedUnique(batches.flatMap { $0 })
    }

    private static func mergedUnique(_ results: [TorrentResult]) -> [TorrentResult] {
        var byHash: [String: TorrentResult] = [:]
        var unhashed: [TorrentResult] = []
        for result in results {
            if let hash = result.resolvedInfoHash {
                if let existing = byHash[hash] {
                    if result.seeders > existing.seeders {
                        byHash[hash] = result
                    }
                } else {
                    byHash[hash] = result
                }
            } else {
                unhashed.append(result)
            }
        }
        return Array(byHash.values) + unhashed
    }

    private static func filterByEnabledIndexers(
        _ results: [TorrentResult],
        enabledIDs: Set<String>
    ) -> [TorrentResult] {
        TorrentIndexerPreferences.filter(results, enabledIDs: enabledIDs)
    }

    private static func sorted(_ results: [TorrentResult]) -> [TorrentResult] {
        results.sorted { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
            if lhs.seeders != rhs.seeders { return lhs.seeders > rhs.seeders }
            return lhs.source.rawValue < rhs.source.rawValue
        }
    }
}

public actor YTSClient {
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared) {
        self.session = session
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    public func search(query: String) async throws -> [TorrentResult] {
        let hosts = ["yts.mx", "yts.pm", "yts.lt", "yts.am"]
        var lastError: Error?

        for host in hosts {
            var components = URLComponents(string: "https://\(host)/api/v2/list_movies.json")
            components?.queryItems = [URLQueryItem(name: "query_term", value: query)]
            guard let url = components?.url else { continue }

            do {
                let (data, _) = try await session.data(from: url)
                let response = try decoder.decode(YTSResponse.self, from: data)
                return response.data.movies?.flatMap { movie in
                    movie.torrents.map { torrent in
                        TorrentResult(
                            title: "\(movie.title) \(torrent.quality) \(torrent.type)",
                            magnetURI: Self.magnet(hash: torrent.hash, title: movie.title),
                            quality: ReleaseParser.parseQuality(from: torrent.quality),
                            hdrType: ReleaseParser.parseHDR(from: "\(torrent.quality) \(torrent.type)"),
                            codec: torrent.videoCodec,
                            audioFormat: nil,
                            source: torrent.type.lowercased().contains("bluray") ? .bluray : .webdl,
                            sizeBytes: torrent.sizeBytes,
                            seeders: torrent.seeds,
                            leechers: torrent.peers,
                            trackerSource: .yts,
                            infoHash: torrent.hash
                        )
                    }
                } ?? []
            } catch {
                NSLog("YTS search failed on \(host): \(error). Trying next mirror...")
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        return []
    }

    private static func magnet(hash: String, title: String) -> String {
        let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        return "magnet:?xt=urn:btih:\(hash)&dn=\(encoded)"
    }
}

private struct YTSResponse: Decodable, Sendable {
    let data: YTSData
}

private struct YTSData: Decodable, Sendable {
    let movies: [YTSMovie]?
}

private struct YTSMovie: Decodable, Sendable {
    let title: String
    let torrents: [YTSTorrent]
}

private struct YTSTorrent: Decodable, Sendable {
    let hash: String
    let quality: String
    let type: String
    let seeds: Int
    let peers: Int
    let sizeBytes: Int64
    let videoCodec: VideoCodec

    enum CodingKeys: String, CodingKey {
        case hash, quality, type, seeds, peers, sizeBytes, videoCodec
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hash = try container.decode(String.self, forKey: .hash)
        quality = try container.decode(String.self, forKey: .quality)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "web"
        seeds = try container.decodeIfPresent(Int.self, forKey: .seeds) ?? 0
        peers = try container.decodeIfPresent(Int.self, forKey: .peers) ?? 0
        sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        let codec = try container.decodeIfPresent(String.self, forKey: .videoCodec) ?? "h264"
        videoCodec = ReleaseParser.parseCodec(from: codec)
    }
}
