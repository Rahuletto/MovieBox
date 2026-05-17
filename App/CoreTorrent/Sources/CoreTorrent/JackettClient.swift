import Foundation

// MARK: - Jackett Client

public actor JackettClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private var apiKey: String
    private var baseURL: URL
    private var port: Int

    public init(apiKey: String = "", host: String = "localhost", port: Int = 9117, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.port = port
        self.session = session
        self.baseURL = URL(string: "http://\(host):\(port)") ?? URL(fileURLWithPath: "")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    public func configure(apiKey: String, host: String, port: Int) {
        self.apiKey = apiKey
        self.port = port
        self.baseURL = URL(string: "http://\(host):\(port)") ?? URL(fileURLWithPath: "")
    }

    public func search(query: String, category: String = "Movies") async throws -> [JackettResult] {
        guard !apiKey.isEmpty else {
            throw JackettError.notConfigured
        }

        var components = URLComponents(url: baseURL.appending(path: "api/v2.0/indexers/all/results"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "Query", value: query),
            URLQueryItem(name: "Category", value: category)
        ]

        guard let url = components?.url else {
            throw JackettError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw JackettError.requestFailed
        }

        let jackettResponse = try decoder.decode(JackettResponse.self, from: data)
        return jackettResponse.results.map { $0.toJackettResult() }
    }

    public func testConnection() async throws -> Bool {
        guard !apiKey.isEmpty else { return false }

        var components = URLComponents(url: baseURL.appending(path: "api/v2.0/server/status"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "apikey", value: apiKey)]

        guard let url = components?.url else { return false }

        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            return false
        }

        let status = try decoder.decode(JackettStatus.self, from: data)
        return status.running
    }
}

public enum JackettError: Error, LocalizedError {
    case notConfigured
    case invalidURL
    case requestFailed

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Jackett is not configured. Set API key and host in Settings."
        case .invalidURL: "Could not build Jackett request URL."
        case .requestFailed: "Jackett request failed. Check host, port, and API key."
        }
    }
}

public struct JackettResult: Sendable, Hashable {
    public let title: String
    public let magnetURI: String
    public let infoHash: String?
    public let sizeBytes: Int64
    public let seeders: Int
    public let leechers: Int
    public let indexer: String
    public let publishDate: Date
    public let link: URL?

    public func toTorrentResult() -> TorrentResult {
        TorrentResult(
            title: title,
            magnetURI: magnetURI,
            quality: ReleaseParser.parseQuality(from: title),
            hdrType: ReleaseParser.parseHDR(from: title),
            codec: ReleaseParser.parseCodec(from: title),
            audioFormat: ReleaseParser.parseAudio(from: title),
            source: ReleaseParser.parseSource(from: title),
            sizeBytes: sizeBytes,
            seeders: seeders,
            leechers: leechers,
            trackerSource: .jackett(indexer: indexer),
            infoHash: infoHash
        )
    }
}

// MARK: - Jackett API Response Models

private struct JackettResponse: Decodable, Sendable {
    let results: [JackettRelease]
}

private struct JackettRelease: Decodable, Sendable {
    let title: String
    let magnetUri: String?
    let infoHash: String?
    let size: Int64
    let seeders: Int
    let peers: Int
    let indexer: String
    let publishDate: String
    let link: String?

    func toJackettResult() -> JackettResult {
        let isoDate = Self.parseDate(publishDate)
        return JackettResult(
            title: title,
            magnetURI: magnetUri ?? "",
            infoHash: infoHash,
            sizeBytes: size,
            seeders: seeders,
            leechers: peers,
            indexer: indexer,
            publishDate: isoDate,
            link: link.flatMap { URL(string: $0) }
        )
    }

    private static func parseDate(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string) ?? Date()
    }
}

private struct JackettStatus: Decodable, Sendable {
    let running: Bool
}
