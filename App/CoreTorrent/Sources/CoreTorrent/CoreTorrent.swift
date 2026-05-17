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
    case jackett(indexer: String)
    case torrentAPI

    public var label: String {
        switch self {
        case .yts: "YTS"
        case .jackett(let indexer): "Jackett: \(indexer)"
        case .torrentAPI: "Torrent API"
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
        infoHash: String? = nil
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
        if t.contains("720") { return .p720 }
        return .p1080
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

public actor TorrentSearchAggregator {
    private let ytsClient: YTSClient
    private var jackettClient: JackettClient?
    private var jackettEnabled: Bool

    public init(ytsClient: YTSClient = YTSClient()) {
        self.ytsClient = ytsClient
        self.jackettEnabled = false
    }

    public func configureJackett(apiKey: String, host: String, port: Int) {
        jackettClient = JackettClient(apiKey: apiKey, host: host, port: port)
        jackettEnabled = true
    }

    public func search(movieTitle: String) -> AsyncStream<[TorrentResult]> {
        AsyncStream { continuation in
            Task {
                var allResults: [TorrentResult] = []

                do {
                    let ytsResults = try await ytsClient.search(query: movieTitle)
                    allResults.append(contentsOf: ytsResults)
                } catch {
                    NSLog("YTS search failed: \(error)")
                }

                if jackettEnabled, let jackett = jackettClient {
                    do {
                        let jackettResults = try await jackett.search(query: movieTitle)
                        allResults.append(contentsOf: jackettResults.map { $0.toTorrentResult() })
                    } catch {
                        NSLog("Jackett search failed: \(error)")
                    }
                }

                continuation.yield(Self.sorted(allResults))
                continuation.finish()
            }
        }
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
        var components = URLComponents(string: "https://yts.mx/api/v2/list_movies.json")
        components?.queryItems = [URLQueryItem(name: "query_term", value: query)]
        guard let url = components?.url else { return [] }
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
