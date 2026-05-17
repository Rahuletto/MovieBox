import Foundation

/// Resolves a real `TorrentMetadata` (piece length, piece hashes, file layout) for a magnet/info-hash.
public enum TorrentMetadataFetcher {
    public struct BackendConfig: Sendable {
        public let baseURL: URL
        public let appToken: String

        public init(baseURL: URL, appToken: String) {
            self.baseURL = baseURL
            self.appToken = appToken
        }
    }

    /// Optional MovieBox backend — tried first (Worker can reach more mirrors than some clients).
    nonisolated(unsafe) private static var backend: BackendConfig?

    public static func configureBackend(baseURL: URL?, appToken: String?) {
        if let baseURL, let appToken, !appToken.isEmpty {
            backend = BackendConfig(baseURL: baseURL, appToken: appToken)
        } else {
            backend = nil
        }
    }

    public enum FetchError: LocalizedError {
        case invalidInfoHash
        case torrentFileUnavailable
        case infoHashMismatch

        public var errorDescription: String? {
            switch self {
            case .invalidInfoHash: "Invalid torrent info hash."
            case .torrentFileUnavailable:
                "Could not download torrent metadata for this release. Try another version from the list."
            case .infoHashMismatch: "Downloaded torrent metadata does not match this magnet link."
            }
        }
    }

    private static let defaultTrackers = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://explodie.org:6969/announce",
        "udp://tracker.openbittorrent.com:6969/announce",
    ]

    public static func fetch(infoHash: String, magnetTrackers: [String] = []) async throws -> TorrentMetadata {
        let normalized = infoHash.lowercased()
        guard normalized.count == 40,
              normalized.range(of: "^[a-f0-9]+$", options: .regularExpression) != nil else {
            throw FetchError.invalidInfoHash
        }

        var trackers = magnetTrackers
        for tracker in defaultTrackers where !trackers.contains(tracker) {
            trackers.append(tracker)
        }
        if trackers.isEmpty {
            trackers = [defaultTrackers[0]]
        }

        if let backend {
            if let data = try? await fetchTorrentBytesFromBackend(hash: normalized, config: backend) {
                if let metadata = try? parseTorrentData(data, expectedHash: normalized, trackers: trackers) {
                    return metadata
                }
            }
        }

        for url in torrentFileURLs(for: normalized) {
            do {
                return try await downloadAndParse(url: url, expectedHash: normalized, trackers: trackers)
            } catch let error as FetchError {
                if case .infoHashMismatch = error { throw error }
            } catch {
                continue
            }
        }

        let peerId = "-MB0001-" + (0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }
        do {
            return try await UTMetadataFetcher.fetch(
                infoHash: normalized,
                trackers: trackers,
                peerId: String(peerId)
            )
        } catch let error as FetchError {
            throw error
        } catch {
            throw FetchError.torrentFileUnavailable
        }
    }

    private static func torrentFileURLs(for hash: String) -> [URL] {
        let upper = hash.uppercased()
        let candidates = [
            "https://itorrents.org/torrent/\(upper).torrent",
            "https://itorrents.org/torrent/\(hash).torrent",
            "http://torrage.info/torrent.php?h=\(hash)",
            "https://btcache.me/torrent/\(hash)",
        ]
        return candidates.compactMap { URL(string: $0) }
    }

    private static func fetchTorrentBytesFromBackend(hash: String, config: BackendConfig) async throws -> Data {
        var components = URLComponents(
            url: config.baseURL.appending(path: "api/torrent/metadata"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "hash", value: hash)]
        guard let url = components?.url else {
            throw FetchError.torrentFileUnavailable
        }

        var request = URLRequest(url: url)
        request.setValue(config.appToken, forHTTPHeaderField: "X-MovieBox-Token")
        request.timeoutInterval = 25

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count > 64 else {
            throw FetchError.torrentFileUnavailable
        }
        return data
    }

    private static func downloadAndParse(url: URL, expectedHash: String, trackers: [String]) async throws -> TorrentMetadata {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("MovieBox/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-bittorrent,*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count > 64 else {
            throw FetchError.torrentFileUnavailable
        }
        return try parseTorrentData(data, expectedHash: expectedHash, trackers: trackers)
    }

    private static func parseTorrentData(
        _ data: Data,
        expectedHash: String,
        trackers: [String]
    ) throws -> TorrentMetadata {
        var metadata = try TorrentFileParser.parse(data: data)
        guard metadata.infoHash.lowercased() == expectedHash else {
            throw FetchError.infoHashMismatch
        }

        var mergedTrackers = metadata.trackers
        for tracker in trackers where !mergedTrackers.contains(tracker) {
            mergedTrackers.append(tracker)
        }

        return TorrentMetadata(
            infoHash: metadata.infoHash,
            name: metadata.name,
            totalSize: metadata.totalSize,
            pieceLength: metadata.pieceLength,
            pieces: metadata.pieces,
            files: metadata.files,
            trackers: mergedTrackers.isEmpty ? defaultTrackers : mergedTrackers
        )
    }
}
