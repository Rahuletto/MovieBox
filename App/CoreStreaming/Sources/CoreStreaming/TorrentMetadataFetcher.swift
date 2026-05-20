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

    public static func configureBackend(baseURL: URL?, appToken: String?) {
        Task {
            await TorrentMetadataBackend.shared.configure(baseURL: baseURL, appToken: appToken)
        }
    }

    public static var hasBackend: Bool {
        get async { await TorrentMetadataBackend.shared.currentConfig() != nil }
    }

    public enum FetchError: LocalizedError {
        case invalidInfoHash
        case torrentFileUnavailable
        case infoHashMismatch
        case backendMetadataFailed
        case backendReturnedInvalidTorrent(statusCode: Int, byteCount: Int)

        public var errorDescription: String? {
            switch self {
            case .invalidInfoHash: "Invalid torrent info hash."
            case .torrentFileUnavailable:
                "Could not download torrent metadata for this release. Try another version from the list."
            case .infoHashMismatch: "Downloaded torrent metadata does not match this magnet link."
            case .backendMetadataFailed:
                "Could not load torrent metadata via your backend or peers. Confirm wrangler is running, then try another release."
            case .backendReturnedInvalidTorrent(let code, let bytes):
                "Backend returned HTTP \(code) with \(bytes) bytes that are not a valid .torrent file (likely an HTML error page from a dead mirror). Peer metadata will be tried next."
            }
        }
    }

    private static let defaultTrackers = [
        "https://tracker.zhuqiy.com:443/announce",
        "https://tracker.yemekyedim.com:443/announce",
        "https://tracker.pmman.tech:443/announce",
        "https://tracker.nekomi.cn:443/announce",
        "https://tracker.moeking.me:443/announce",
        "https://tracker.leechshield.link:443/announce",
        "https://tracker.bt4g.com:443/announce",
        "https://tr.nyacat.pw:443/announce",
        "https://torrents.tmtime.dev:443/announce",
        "https://pybittrack.retiolus.net:443/announce",
        "https://open.ftorrent.com:443/announce",
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://explodie.org:6969/announce",
        "udp://tracker.openbittorrent.com:6969/announce",
        "http://tracker.opentrackr.org:1337/announce",
        "http://tracker2.dler.org:80/announce",
        "http://tracker.sbsub.com:2710/announce",
        "http://tracker.qu.ax:6969/announce",
        "http://open.trackerlist.xyz:80/announce",
    ]

    public static func fetch(infoHash: String, magnetTrackers: [String] = []) async throws -> TorrentMetadata {
        let normalized = infoHash.lowercased()
        do {
            return try await TaskTimeout.withTimeout(seconds: 55) {
                try await TorrentMetadataCache.shared.fetch(infoHash: normalized, magnetTrackers: magnetTrackers) {
                    try await fetchResolved(infoHash: normalized, magnetTrackers: magnetTrackers)
                }
            }
        } catch is TaskTimeoutError {
            throw FetchError.torrentFileUnavailable
        }
    }

    /// Fire-and-forget: warms metadata cache while the user browses releases on the detail page.
    public static func prewarm(infoHash: String, magnetTrackers: [String] = []) {
        let normalized = infoHash.lowercased()
        Task {
            _ = try? await fetch(infoHash: normalized, magnetTrackers: magnetTrackers)
        }
    }

    private static func fetchResolved(infoHash: String, magnetTrackers: [String]) async throws -> TorrentMetadata {
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

        let backend = await TorrentMetadataBackend.shared.currentConfig()
        let peerId = BitTorrentPeerID.make()
        let trackerList = trackers

        return try await withThrowingTaskGroup(of: TorrentMetadata.self) { group in
            if let backend {
                group.addTask {
                    let data = try await fetchTorrentBytesFromBackend(hash: normalized, config: backend)
                    return try parseTorrentData(data, expectedHash: normalized, trackers: trackerList)
                }
            }

            group.addTask {
                try await TaskTimeout.withTimeout(seconds: 35) {
                    try await UTMetadataFetcher.fetch(
                        infoHash: normalized,
                        trackers: trackerList,
                        peerId: String(peerId)
                    )
                }
            }

            group.addTask {
                try await fetchFirstMirror(hash: normalized, trackers: trackerList)
            }

            var lastError: Error = FetchError.torrentFileUnavailable

            while let result = await group.nextResult() {
                switch result {
                case .success(let metadata):
                    group.cancelAll()
                    return metadata
                case .failure(let error as FetchError):
                    if case .infoHashMismatch = error {
                        group.cancelAll()
                        throw error
                    }
                    lastError = error
                case .failure(let error):
                    lastError = error
                }
            }

            throw lastError
        }
    }

    /// Tries public `.torrent` mirrors in parallel (skips broken TLS hosts like btcache.me).
    private static func fetchFirstMirror(hash: String, trackers: [String]) async throws -> TorrentMetadata {
        let urls = torrentFileURLs(for: hash)
        let trackerList = trackers
        return try await withThrowingTaskGroup(of: TorrentMetadata.self) { group in
            for url in urls {
                group.addTask {
                    try await downloadAndParse(url: url, expectedHash: hash, trackers: trackerList)
                }
            }

            var lastError: Error = FetchError.torrentFileUnavailable
            while let result = await group.nextResult() {
                switch result {
                case .success(let metadata):
                    group.cancelAll()
                    return metadata
                case .failure(let error as FetchError):
                    if case .infoHashMismatch = error {
                        group.cancelAll()
                        throw error
                    }
                    lastError = error
                case .failure(let error):
                    lastError = error
                }
            }
            throw lastError
        }
    }

    private static func torrentFileURLs(for hash: String) -> [URL] {
        let upper = hash.uppercased()
        // HTTP torrage only — HTTPS mirror hosts often fail TLS on macOS with system proxy/VPN.
        let candidates = [
            "http://torrage.info/torrent.php?h=\(hash)",
            "https://itorrents.org/torrent/\(upper).torrent",
            // Proxy fallbacks to bypass school/ISP SNI blocks during local direct calls
            "https://api.codetabs.com/v1/proxy/?quest=https://itorrents.org/torrent/\(upper).torrent",
            "https://api.codetabs.com/v1/proxy/?quest=https://itorrents.org/torrent/\(hash).torrent",
        ]
        return candidates.compactMap { URL(string: $0) }
    }

    private static func fetchTorrentBytesFromBackend(hash: String, config: BackendConfig) async throws -> Data {
        guard let url = BackendURLSession.metadataURL(baseURL: config.baseURL, infoHash: hash) else {
            throw FetchError.torrentFileUnavailable
        }

        var request = URLRequest(url: url)
        request.setValue(config.appToken, forHTTPHeaderField: "X-MovieBox-Token")
        request.setValue("application/x-bittorrent,*/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await BackendURLSession.direct.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.torrentFileUnavailable
        }

        if http.statusCode == 404 {
            throw FetchError.torrentFileUnavailable
        }

        guard (200..<300).contains(http.statusCode) else {
            throw FetchError.torrentFileUnavailable
        }

        if data.first == 0x7B {
            // JSON error body from backend, e.g. {"error":"metadata_unavailable"}
            throw FetchError.torrentFileUnavailable
        }

        guard isTorrentFileData(data) else {
            throw FetchError.backendReturnedInvalidTorrent(
                statusCode: http.statusCode,
                byteCount: data.count
            )
        }

        return data
    }

    private static func isTorrentFileData(_ data: Data) -> Bool {
        guard data.count >= 64 else { return false }
        return data.first == 0x64
    }

    private static func downloadAndParse(url: URL, expectedHash: String, trackers: [String]) async throws -> TorrentMetadata {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
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
