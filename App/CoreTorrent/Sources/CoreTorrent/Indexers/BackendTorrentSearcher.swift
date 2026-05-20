import Foundation

/// Single backend call for all torrent sources (Torrentio + indexers). Indexer logic lives on the Worker.
public struct BackendTorrentSearcher: Sendable {
    private static let defaultStreamSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 120
        return URLSession(configuration: config)
    }()

    private let baseURL: URL
    private let appToken: String
    private let session: URLSession
    private let streamSession: URLSession

    public init(
        baseURL: URL,
        appToken: String,
        session: URLSession = .shared,
        streamSession: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.appToken = appToken
        self.session = session
        self.streamSession = streamSession ?? Self.defaultStreamSession
    }

    public struct SearchResponse: Sendable {
        public let results: [TorrentResult]
        public let diagnostics: TorrentSearchDiagnostics
        public let apiVersion: Int
    }

    public func search(
        query: String,
        year: Int?,
        imdbId: String?,
        kind: TorrentioClient.MediaKind,
        enabledIndexerIDs: Set<String>
    ) async throws -> SearchResponse {
        var components = URLComponents(url: baseURL.appending(path: "api/torrent/search"), resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "kind", value: kind.rawValue),
            URLQueryItem(name: "enabled", value: TorrentIndexerPreferences.serialize(enabledIndexerIDs)),
        ]
        if let year { items.append(URLQueryItem(name: "year", value: String(year))) }
        if let imdbId, !imdbId.isEmpty { items.append(URLQueryItem(name: "imdbId", value: imdbId)) }
        components?.queryItems = items
        guard let url = components?.url else {
            return SearchResponse(results: [], diagnostics: TorrentSearchDiagnostics(), apiVersion: 0)
        }

        var request = URLRequest(url: url)
        request.setValue(appToken, forHTTPHeaderField: "X-MovieBox-Token")
        request.timeoutInterval = 45

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "BackendTorrentSearcher", code: code, userInfo: [
                NSLocalizedDescriptionKey: "Backend torrent search failed (HTTP \(code))",
            ])
        }

        if let errorBody = try? JSONDecoder().decode(BackendTorrentErrorResponse.self, from: data),
           let message = errorBody.message ?? errorBody.error {
            throw NSError(domain: "BackendTorrentSearcher", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }

        let payload: BackendTorrentSearchResponse
        do {
            payload = try JSONDecoder().decode(BackendTorrentSearchResponse.self, from: data)
        } catch {
            let snippet = String(data: data.prefix(240), encoding: .utf8) ?? ""
            throw NSError(domain: "BackendTorrentSearcher", code: -3, userInfo: [
                NSLocalizedDescriptionKey:
                    "Backend returned unexpected JSON (HTTP \(http.statusCode)). \(snippet.isEmpty ? "Check proxy URL and app token." : snippet)",
                NSUnderlyingErrorKey: error,
            ])
        }
        var diagnostics = TorrentSearchDiagnostics()
        diagnostics.queryUsed = payload.query ?? query
        diagnostics.torrentioAttempted = payload.torrentio?.attempted ?? false
        diagnostics.torrentioCount = payload.torrentio?.count ?? payload.counts?["torrentio"] ?? 0
        diagnostics.torrentioError = payload.torrentio?.error
        diagnostics.nativeCounts = payload.counts ?? [:]
        diagnostics.nativeErrors = payload.errors ?? [:]
        diagnostics.ytsCount = payload.counts?["yts"] ?? 0
        diagnostics.ytsAttempted = enabledIndexerIDs.contains("yts") && kind == .movie

        let results = payload.results.map { $0.torrentResult }
        return SearchResponse(
            results: results,
            diagnostics: diagnostics,
            apiVersion: payload.apiVersion ?? 0
        )
    }

    public enum StreamEvent: Sendable {
        case batch(indexer: String, results: [TorrentResult])
        case done(diagnostics: TorrentSearchDiagnostics, apiVersion: Int)
        case fatal(message: String)
    }

    public func searchStream(
        query: String,
        year: Int?,
        imdbId: String?,
        kind: TorrentioClient.MediaKind,
        enabledIndexerIDs: Set<String>
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let baseURL = baseURL
        let appToken = appToken
        let streamSession = streamSession
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var components = URLComponents(
                        url: baseURL.appending(path: "api/torrent/search/stream"),
                        resolvingAgainstBaseURL: false
                    )
                    var items = [
                        URLQueryItem(name: "q", value: query),
                        URLQueryItem(name: "kind", value: kind.rawValue),
                        URLQueryItem(name: "enabled", value: TorrentIndexerPreferences.serialize(enabledIndexerIDs)),
                    ]
                    if let year { items.append(URLQueryItem(name: "year", value: String(year))) }
                    if let imdbId, !imdbId.isEmpty { items.append(URLQueryItem(name: "imdbId", value: imdbId)) }
                    components?.queryItems = items
                    guard let url = components?.url else {
                        continuation.finish()
                        return
                    }

                    var request = URLRequest(url: url)
                    request.setValue(appToken, forHTTPHeaderField: "X-MovieBox-Token")
                    request.timeoutInterval = 120
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let (bytes, response) = try await streamSession.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                        throw NSError(domain: "BackendTorrentSearcher", code: code, userInfo: [
                            NSLocalizedDescriptionKey: "Backend torrent stream failed (HTTP \(code))",
                        ])
                    }

                    let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
                    guard contentType.contains("text/event-stream") else {
                        throw NSError(domain: "BackendTorrentSearcher", code: -2, userInfo: [
                            NSLocalizedDescriptionKey:
                                "Backend returned non-SSE response (\(contentType.isEmpty ? "unknown type" : contentType)). Rebuild/deploy the Worker or check the proxy URL.",
                        ])
                    }

                    let decoder = JSONDecoder()
                    for try await event in TorrentSearchSSEParser.events(from: bytes) {
                        switch event.event {
                        case "ready":
                            continue
                        case "batch":
                            do {
                                let payload = try TorrentSearchSSEParser.decode(
                                    SSEBatchPayload.self,
                                    from: event.data,
                                    decoder: decoder
                                )
                                let results = payload.results.map(\.torrentResult)
                                if !results.isEmpty {
                                    continuation.yield(.batch(indexer: payload.indexer, results: results))
                                }
                            } catch {
                                NSLog("SSE batch decode failed for \(event.data.prefix(120)): \(error)")
                                continue
                            }
                        case "done":
                            let payload = try TorrentSearchSSEParser.decode(
                                SSEDonePayload.self,
                                from: event.data,
                                decoder: decoder
                            )
                            var diagnostics = TorrentSearchDiagnostics()
                            diagnostics.queryUsed = payload.query ?? query
                            diagnostics.torrentioAttempted = payload.torrentio?.attempted ?? false
                            diagnostics.torrentioCount = payload.torrentio?.count ?? payload.counts?["torrentio"] ?? 0
                            diagnostics.torrentioError = payload.torrentio?.error
                            diagnostics.nativeCounts = payload.counts ?? [:]
                            diagnostics.nativeErrors = payload.errors ?? [:]
                            diagnostics.ytsAttempted = enabledIndexerIDs.contains("yts") && kind == .movie
                            diagnostics.ytsCount = payload.counts?["yts"] ?? 0
                            continuation.yield(.done(
                                diagnostics: diagnostics,
                                apiVersion: payload.apiVersion ?? 0
                            ))
                        case "error":
                            let payload = try TorrentSearchSSEParser.decode(
                                SSEErrorPayload.self,
                                from: event.data,
                                decoder: decoder
                            )
                            continuation.yield(.fatal(message: payload.message))
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

enum TorrentSearchSSEParser {
    struct Accumulator {
        var eventName = "message"
        var dataLines: [String] = []

        mutating func reset() {
            eventName = "message"
            dataLines.removeAll(keepingCapacity: true)
        }

        var payload: String? {
            guard !dataLines.isEmpty else { return nil }
            return dataLines.joined(separator: "\n")
        }

        mutating func takePayload() -> (event: String, data: String)? {
            guard let payload else { return nil }
            let event = eventName
            reset()
            return (event: event, data: payload)
        }
    }

    /// URLSession may deliver `\r\n`; a lone `\r` line must count as the event delimiter.
    private static func normalizedSSELine(_ line: String) -> String {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
    }

    private static func isEventDelimiter(_ line: String) -> Bool {
        normalizedSSELine(line).isEmpty
    }

    static func events(from bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<(event: String, data: String), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var accumulator = Accumulator()
                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            throw CancellationError()
                        }

                        let normalized = normalizedSSELine(line)

                        if isEventDelimiter(line) {
                            if let event = accumulator.takePayload() {
                                continuation.yield(event)
                            } else {
                                accumulator.reset()
                            }
                            continue
                        }

                        if normalized.hasPrefix(":") {
                            continue
                        }

                        if normalized.hasPrefix("event:") {
                            // Defensive: new event name without a blank line (bad framing).
                            if let event = accumulator.takePayload() {
                                continuation.yield(event)
                            }
                            accumulator.eventName = String(normalized.dropFirst(6))
                                .trimmingCharacters(in: .whitespaces)
                            continue
                        }

                        if normalized.hasPrefix("data:") {
                            var value = String(normalized.dropFirst(5))
                            if value.first == " " {
                                value.removeFirst()
                            }
                            accumulator.dataLines.append(value)
                        }
                    }

                    if let event = accumulator.takePayload() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from payload: String, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = try? decoder.decode(T.self, from: Data(trimmed.utf8)) {
            return decoded
        }
        // Recover from accidentally merged JSON objects (take the last valid line).
        for line in trimmed.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let piece = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard piece.hasPrefix("{") else { continue }
            if let decoded = try? decoder.decode(T.self, from: Data(piece.utf8)) {
                return decoded
            }
        }
        return try decoder.decode(T.self, from: Data(trimmed.utf8))
    }
}

struct SSEBatchPayload: Decodable, Sendable {
    let indexer: String
    let results: [BackendTorrentHit]
    let count: Int?
    let error: String?
}

struct SSEDonePayload: Decodable, Sendable {
    let query: String?
    let counts: [String: Int]?
    let errors: [String: String]?
    let torrentio: BackendTorrentioMeta?
    let apiVersion: Int?
}

struct SSEErrorPayload: Decodable, Sendable {
    let message: String
}

struct BackendTorrentErrorResponse: Decodable, Sendable {
    let error: String?
    let message: String?
}

struct BackendTorrentSearchResponse: Decodable, Sendable {
    let results: [BackendTorrentHit]
    let counts: [String: Int]?
    let errors: [String: String]?
    let query: String?
    let torrentio: BackendTorrentioMeta?
    let apiVersion: Int?
}

struct BackendTorrentioMeta: Decodable, Sendable {
    let attempted: Bool?
    let count: Int?
    let error: String?
}

struct BackendTorrentHit: Decodable, Sendable {
    let title: String
    let magnetURI: String
    let infoHash: String?
    let quality: String?
    let sizeBytes: Int64?
    let seeders: Int?
    let leechers: Int?
    let trackerSource: String

    var torrentResult: TorrentResult {
        let source: TrackerSource
        if trackerSource.lowercased() == "torrentio" {
            source = .torrentio
        } else {
            source = .native(site: trackerSource)
        }

        return TorrentResult(
            title: title,
            magnetURI: magnetURI,
            quality: ReleaseParser.resolveQuality(indexerLabel: quality, title: title),
            hdrType: ReleaseParser.parseHDR(from: title),
            codec: ReleaseParser.parseCodec(from: title),
            audioFormat: ReleaseParser.parseAudio(from: title),
            source: ReleaseParser.parseSource(from: title),
            sizeBytes: sizeBytes ?? 0,
            seeders: seeders ?? 0,
            leechers: leechers ?? 0,
            trackerSource: source,
            infoHash: infoHash
        )
    }
}
