import CoreStorage
import Foundation
import Network

// MARK: - HTTP Range Server

@MainActor
public final class HTTPRangeServer {
    public private(set) var port: UInt16 = 0
    public private(set) var isRunning = false

    private var listener: NWListener?
    private var pieceStore: PieceStore?
    private var pieceManager: PieceManager?
    private var streamByteOffset: Int64 = 0
    private var streamByteLength: Int64 = 0
    private var contentType = "application/octet-stream"

    /// When set, AVPlayer requests are translated through a synthesized fast-start MP4
    /// layout (moov at byte 0). Synthesized header bytes are served from memory; the
    /// remainder maps to original mdat content on disk.
    public private(set) var remuxedLayout: MP4FastStartRemuxer.RemuxedLayout?

    /// Coalesces concurrent identical torrent-range reads — AVPlayer often issues
    /// 6–8 parallel range requests for the same bytes; we keep a single inflight
    /// reader and fan the result out to all waiters.
    private var pendingRangeWaiters: [String: [CheckedContinuation<Data, Error>]] = [:]

    public var onPlayerRead: (@Sendable (Int64, Int) async -> Void)?

    /// Monotonic id for temporary AVPlayer range-request tracing.
    private var rangeRequestSequence = 0

    private static let maxRangeBytes = 32 * 1024 * 1024
    private static let readTimeoutSeconds: UInt64 = 300
    private static let bufferWaitSeconds: UInt64 = 300

    public init() {}

    /// Configures stream byte mapping without starting the TCP listener (unit tests).
    func configureForTests(
        pieceStore: PieceStore,
        streamTarget: TorrentStreamTarget,
        pieceManager: PieceManager? = nil
    ) {
        self.pieceStore = pieceStore
        self.pieceManager = pieceManager
        streamByteOffset = streamTarget.byteOffset
        streamByteLength = streamTarget.byteLength
        contentType = streamTarget.contentType
    }

    public func start(
        pieceStore: PieceStore,
        streamTarget: TorrentStreamTarget,
        pieceManager: PieceManager? = nil,
        preferredPort: UInt16 = 0
    ) async throws -> URL {
        self.pieceStore = pieceStore
        self.pieceManager = pieceManager
        self.streamByteOffset = streamTarget.byteOffset
        self.streamByteLength = streamTarget.byteLength
        self.contentType = streamTarget.contentType

        let parameters = NWParameters.tcp
        let nwPort: NWEndpoint.Port
        if preferredPort > 0, let port = NWEndpoint.Port(rawValue: preferredPort) {
            nwPort = port
        } else {
            nwPort = NWEndpoint.Port.any
        }
        listener = try NWListener(using: parameters, on: nwPort)

        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    self?.isRunning = true
                case .failed(let error):
                    self?.isRunning = false
                    TorrentLog.warn("[HTTPRangeServer] Listener failed: \(error)")
                case .cancelled:
                    self?.isRunning = false
                default:
                    break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { @MainActor in
                await self.handleConnection(connection)
            }
        }

        listener?.start(queue: .main)

        try await Task.sleep(for: .milliseconds(500))
        guard let port = listener?.port else {
            throw HTTPRangeServerError.failedToStart
        }
        self.port = port.rawValue
        guard let url = URL(string: "http://127.0.0.1:\(port)/stream") else {
            throw HTTPRangeServerError.failedToStart
        }
        TorrentLog.info(
            "[HTTPRangeServer] listening on port \(port.rawValue) — \(MovieBoxFileLogger.redactURL(url)) length=\(self.streamByteLength) offset=\(self.streamByteOffset)"
        )
        return url
    }

    public func stop() async {
        isRunning = false
        listener?.cancel()
        listener = nil
        pieceStore = nil
        pieceManager = nil
        onPlayerRead = nil
        remuxedLayout = nil
        // Fail any pending waiters so we don't leak continuations
        let pending = pendingRangeWaiters
        pendingRangeWaiters.removeAll()
        for (_, waiters) in pending {
            for waiter in waiters {
                waiter.resume(throwing: CancellationError())
            }
        }
    }

    /// Patches the server to serve a virtual fast-start MP4 layout.
    /// Safe to call after `start()` — subsequent range requests will translate
    /// through the synthetic header + remapped mdat content.
    public func setRemuxedLayout(_ layout: MP4FastStartRemuxer.RemuxedLayout) {
        remuxedLayout = layout
        TorrentLog.info(
            "[HTTPRangeServer] Fast-start remux installed — virtual length \(layout.virtualFileLength) header \(layout.syntheticHeader.count) B"
        )
    }

    private func handleConnection(_ connection: NWConnection) async {
        guard let pieceStore else {
            connection.cancel()
            return
        }

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            if case .ready = state {
                connection.stateUpdateHandler = nil
                Task { @MainActor [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.receiveHTTPRequest(connection: connection, pieceStore: pieceStore)
                }
            }
        }
        connection.start(queue: .main)
    }

    private static let maxRequestHeaderBytes = 64 * 1024

    private func receiveHTTPRequest(connection: NWConnection, pieceStore: PieceStore, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                TorrentLog.debug("[HTTPRangeServer] Receive error: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            var requestBuffer = buffer
            if let data, !data.isEmpty {
                requestBuffer.append(data)
            }

            // SECURITY: Cap the accumulation buffer to prevent a local process flooding
            // the socket and growing this Data object without bound.
            if requestBuffer.count > Self.maxRequestHeaderBytes {
                TorrentLog.warn("[HTTPRangeServer] Request header too large (\(requestBuffer.count) bytes) — dropping connection")
                connection.cancel()
                return
            }

            if let requestEnd = requestBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = requestBuffer[..<requestEnd.lowerBound]
                guard let request = String(data: headerData, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                let responseTask = Task { @MainActor [weak self, weak connection] in
                    guard let self, let connection else { return }
                    let response = await self.handleRequest(request, pieceStore: pieceStore)
                    self.sendResponse(connection: connection, response: response)
                    connection.stateUpdateHandler = nil
                }
                connection.stateUpdateHandler = { [weak connection] state in
                    switch state {
                    case .cancelled, .failed:
                        responseTask.cancel()
                        connection?.stateUpdateHandler = nil
                    default:
                        break
                    }
                }
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection else { return }
                self.receiveHTTPRequest(connection: connection, pieceStore: pieceStore, buffer: requestBuffer)
            }
        }
    }

    func handleRequest(_ request: String, pieceStore: PieceStore) async -> HTTPResponse {
        rangeRequestSequence += 1
        let rangeReqID = rangeRequestSequence

        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return HTTPResponse(status: 400, body: "Bad Request")
        }

        // SECURITY: DNS rebinding protection.
        // A web page could bind its domain to 127.0.0.1:PORT and read torrent bytes via
        // JavaScript fetch(). Reject any request whose Host header is not the loopback address.
        let hostHeader = lines
            .first { $0.lowercased().hasPrefix("host:") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces).lowercased() }
        // Accept 127.0.0.1, 127.0.0.1:PORT, localhost, localhost:PORT, and empty (direct connections).
        let allowedHosts: Set<String> = ["127.0.0.1", "localhost", ""]
        let bareHost = hostHeader.map { $0.components(separatedBy: ":").first ?? $0 } ?? ""
        guard allowedHosts.contains(bareHost) else {
            TorrentLog.warn("[HTTPRangeServer] Rejected request with non-loopback Host: \(hostHeader ?? "<nil>")")
            return HTTPResponse(status: 403, body: "Forbidden")
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            return HTTPResponse(status: 400, body: "Bad Request")
        }
        let method = parts[0].uppercased()
        guard method == "GET" || method == "HEAD" else {
            return HTTPResponse(status: 405, body: "Method Not Allowed")
        }

        // The "media length" presented to AVPlayer: virtual length when remuxing,
        // raw stream length otherwise.
        let mediaLength = remuxedLayout?.virtualFileLength ?? streamByteLength
        let rangeHeaderValue = lines
            .first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }

        var statusCode = 200
        var bodyData = Data()
        var contentRange: String?
        var contentLength = mediaLength

        if let rangeHeader = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            let rangeParts = rangeHeader.components(separatedBy: "=")
            if rangeParts.count == 2 {
                let byteRange = rangeParts[1]
                let rangeComponents = byteRange.components(separatedBy: "-")
                let startStr = rangeComponents.first ?? ""
                let endStr = rangeComponents.count > 1 ? rangeComponents[1] : ""

                let mediaStart: Int64
                let mediaEnd: Int64
                let isSuffixRange: Bool
                if startStr.isEmpty, !endStr.isEmpty, let suffixLength = Int64(endStr) {
                    isSuffixRange = true
                    // Suffix range: bytes=-500 (common for end-of-file index probes).
                    let clampedSuffix = min(suffixLength, mediaLength)
                    mediaStart = max(0, mediaLength - clampedSuffix)
                    mediaEnd = mediaLength - 1
                } else if let parsedStart = Int64(startStr) {
                    isSuffixRange = false
                    mediaStart = parsedStart
                    if !endStr.isEmpty, let parsedEnd = Int64(endStr) {
                        mediaEnd = min(parsedEnd, mediaLength - 1)
                    } else {
                        mediaEnd = mediaLength - 1
                    }
                } else {
                    isSuffixRange = false
                    mediaStart = -1
                    mediaEnd = -1
                }

                if mediaStart >= 0 {
                    guard mediaStart < mediaLength, mediaEnd >= mediaStart else {
                        return HTTPResponse(status: 416, body: "Range Not Satisfiable")
                    }

                    // AVPlayer often sends open-ended ranges (e.g. bytes=0-). Cap the span
                    // instead of 416 — oversized ranges surface as "unknown error" in AVFoundation.
                    let maxSpan = Int64(Self.maxRangeBytes)
                    var cappedEnd = mediaEnd
                    if cappedEnd - mediaStart + 1 > maxSpan {
                        cappedEnd = mediaStart + maxSpan - 1
                    }

                    let span = cappedEnd &- mediaStart
                    let spanPlusOne = span &+ 1
                    guard spanPlusOne > 0 else {
                        return HTTPResponse(status: 416, body: "Range Not Satisfiable")
                    }
                    var length = Int(spanPlusOne)
                    length = min(length, Self.maxRangeBytes)

                    logRangeServerRequest(
                        id: rangeReqID,
                        method: method,
                        rangeHeader: rangeHeaderValue,
                        mediaStart: mediaStart,
                        mediaEnd: mediaEnd,
                        length: length
                    )

                    await notifyPlayerRead(mediaOffset: mediaStart, length: length)

                    let resolution = resolveVirtualRange(mediaStart: mediaStart, length: length)

                    switch resolution {
                    case .syntheticHeaderBytes(let data):
                        // Served entirely from the synthesized fast-start header in memory —
                        // no disk wait, no torrent traffic needed.
                        bodyData = data
                        let headerServeStart = mediaStart
                        let headerServeEnd = mediaStart + Int64(data.count) - 1
                        statusCode = 206
                        contentRange = "bytes \(headerServeStart)-\(headerServeEnd)/\(mediaLength)"
                        contentLength = Int64(bodyData.count)
                        logRangeServerResponse(
                            id: rangeReqID,
                            statusCode: statusCode,
                            servedBytes: bodyData.count,
                            torrentOffset: -1,
                            wasReadable: true
                        )

                    case .rawTorrentBytes(let torrentOffset, let resolvedLength):
                        guard let resolvedSpan = await waitForReadableSpan(
                            pieceStore: pieceStore,
                            offset: torrentOffset,
                            length: resolvedLength,
                            preferSuffix: isSuffixRange
                        ) else {
                            TorrentLog.warn(
                                "[HTTPRangeServer] No readable bytes for range \(mediaStart)-\(mediaEnd) (suffix=\(isSuffixRange)) after \(Self.bufferWaitSeconds)s — " +
                                "torrentOffset=\(torrentOffset) (AVPlayer may be probing for moov)"
                            )
                            DebugSessionLog.event(
                                "range_unreadable",
                                location: "HTTPRangeServer.handleRange",
                                data: [
                                    "mediaStart": mediaStart,
                                    "mediaEnd": mediaEnd,
                                    "suffix": isSuffixRange,
                                    "torrentOffset": torrentOffset,
                                ]
                            )
                            return logRangeServerAndReturn(
                                id: rangeReqID,
                                response: HTTPResponse(status: 503, body: "Buffering", retryAfterSeconds: 1),
                                statusCode: 503,
                                servedBytes: 0,
                                torrentOffset: torrentOffset,
                                wasReadable: false
                            )
                        }

                        let serveOffset = resolvedSpan.offset
                        let serveLength = resolvedSpan.length

                        do {
                            bodyData = try await waitForTorrentRange(
                                pieceStore: pieceStore,
                                offset: serveOffset,
                                length: serveLength
                            )
                            guard bodyData.count == serveLength else {
                                TorrentLog.warn(
                                    "[HTTPRangeServer] Short read \(bodyData.count)/\(serveLength) at \(mediaStart) — still buffering"
                                )
                                return logRangeServerAndReturn(
                                    id: rangeReqID,
                                    response: HTTPResponse(status: 503, body: "Buffering", retryAfterSeconds: 1),
                                    statusCode: 503,
                                    servedBytes: bodyData.count,
                                    torrentOffset: serveOffset,
                                    wasReadable: false
                                )
                            }
                            // Translate the served torrent offset back to virtual media coordinates
                            // so AVPlayer's Content-Range matches what it requested.
                            let mdatServeStart = virtualMediaOffset(forTorrentOffset: serveOffset)
                            let mdatServeEnd = mdatServeStart + Int64(bodyData.count) - 1
                            statusCode = 206
                            contentRange = "bytes \(mdatServeStart)-\(mdatServeEnd)/\(mediaLength)"
                            contentLength = Int64(bodyData.count)
                            logRangeServerResponse(
                                id: rangeReqID,
                                statusCode: statusCode,
                                servedBytes: bodyData.count,
                                torrentOffset: serveOffset,
                                wasReadable: true
                            )
                        } catch is CancellationError {
                        return logRangeServerAndReturn(
                            id: rangeReqID,
                            response: HTTPResponse(status: 499, body: "Client Closed Request"),
                            statusCode: 499,
                            servedBytes: 0,
                            torrentOffset: torrentOffset,
                            wasReadable: false
                        )
                    } catch is HTTPRangeReadTimeout {
                        TorrentLog.warn(
                            "[HTTPRangeServer] Range \(mediaStart)-\(mediaEnd) timed out after \(Self.readTimeoutSeconds)s — still buffering"
                        )
                        return logRangeServerAndReturn(
                            id: rangeReqID,
                            response: HTTPResponse(status: 503, body: "Buffering", retryAfterSeconds: 2),
                            statusCode: 503,
                            servedBytes: 0,
                            torrentOffset: torrentOffset,
                            wasReadable: false
                        )
                    } catch let error as PieceStoreError {
                        if case .readTimeout = error {
                            TorrentLog.warn(
                                "[HTTPRangeServer] PieceStore read timeout at \(mediaStart) — still buffering"
                            )
                            return logRangeServerAndReturn(
                                id: rangeReqID,
                                response: HTTPResponse(status: 503, body: "Buffering", retryAfterSeconds: 2),
                                statusCode: 503,
                                servedBytes: 0,
                                torrentOffset: torrentOffset,
                                wasReadable: false
                            )
                        } else {
                            TorrentLog.warn("[HTTPRangeServer] Range read failed: \(error.localizedDescription)")
                            return logRangeServerAndReturn(
                                id: rangeReqID,
                                response: HTTPResponse(status: 500, body: "Internal Server Error"),
                                statusCode: 500,
                                servedBytes: 0,
                                torrentOffset: torrentOffset,
                                wasReadable: false
                            )
                        }
                    } catch {
                        TorrentLog.warn("[HTTPRangeServer] Range read failed: \(error.localizedDescription)")
                        return logRangeServerAndReturn(
                            id: rangeReqID,
                            response: HTTPResponse(status: 500, body: "Internal Server Error"),
                            statusCode: 500,
                            servedBytes: 0,
                            torrentOffset: torrentOffset,
                            wasReadable: false
                        )
                    }
                    } // close switch resolution
                }     // close if mediaStart >= 0
            }         // close if rangeParts.count == 2
        } else if method == "GET" {
            let length = min(512 * 1024, Int(mediaLength))
            logRangeServerRequest(
                id: rangeReqID,
                method: method,
                rangeHeader: rangeHeaderValue,
                mediaStart: 0,
                mediaEnd: max(0, mediaLength - 1),
                length: length
            )
            await notifyPlayerRead(mediaOffset: 0, length: length)
            guard let span = await waitForReadableSpan(
                pieceStore: pieceStore,
                offset: streamByteOffset,
                length: length,
                preferSuffix: false
            ) else {
                return logRangeServerAndReturn(
                    id: rangeReqID,
                    response: HTTPResponse(status: 503, body: "Buffering", retryAfterSeconds: 1),
                    statusCode: 503,
                    servedBytes: 0,
                    torrentOffset: streamByteOffset,
                    wasReadable: false
                )
            }
            do {
                bodyData = try await readBytes(
                    pieceStore: pieceStore,
                    offset: span.offset,
                    length: span.length
                )
                guard bodyData.count == span.length else {
                    return HTTPResponse(status: 503, body: "Buffering", retryAfterSeconds: 1)
                }
                contentLength = Int64(bodyData.count)
                logRangeServerResponse(
                    id: rangeReqID,
                    statusCode: statusCode,
                    servedBytes: bodyData.count,
                    torrentOffset: span.offset,
                    wasReadable: true
                )
            } catch is CancellationError {
                return logRangeServerAndReturn(
                    id: rangeReqID,
                    response: HTTPResponse(status: 499, body: "Client Closed Request"),
                    statusCode: 499,
                    servedBytes: 0,
                    torrentOffset: span.offset,
                    wasReadable: false
                )
            } catch is HTTPRangeReadTimeout {
                return logRangeServerAndReturn(
                    id: rangeReqID,
                    response: HTTPResponse(status: 503, body: "Buffering", retryAfterSeconds: 1),
                    statusCode: 503,
                    servedBytes: 0,
                    torrentOffset: span.offset,
                    wasReadable: false
                )
            } catch let error as PieceStoreError {
                if case .readTimeout = error {
                    return logRangeServerAndReturn(
                        id: rangeReqID,
                        response: HTTPResponse(status: 503, body: "Buffering", retryAfterSeconds: 1),
                        statusCode: 503,
                        servedBytes: 0,
                        torrentOffset: span.offset,
                        wasReadable: false
                    )
                } else {
                    return logRangeServerAndReturn(
                        id: rangeReqID,
                        response: HTTPResponse(status: 500, body: "Internal Server Error"),
                        statusCode: 500,
                        servedBytes: 0,
                        torrentOffset: span.offset,
                        wasReadable: false
                    )
                }
            } catch {
                return logRangeServerAndReturn(
                    id: rangeReqID,
                    response: HTTPResponse(status: 500, body: "Internal Server Error"),
                    statusCode: 500,
                    servedBytes: 0,
                    torrentOffset: span.offset,
                    wasReadable: false
                )
            }
        } else {
            logRangeServerRequest(
                id: rangeReqID,
                method: method,
                rangeHeader: rangeHeaderValue,
                mediaStart: 0,
                mediaEnd: max(0, mediaLength - 1),
                length: 0
            )
            contentLength = mediaLength
            logRangeServerResponse(
                id: rangeReqID,
                statusCode: statusCode,
                servedBytes: 0,
                torrentOffset: streamByteOffset,
                wasReadable: method == "HEAD"
            )
        }

        var headers = [
            "HTTP/1.1 \(statusCode) \(HTTPResponse.statusMessage(for: statusCode))",
            "Content-Type: \(contentType)",
            "Content-Length: \(contentLength)",
            "Accept-Ranges: bytes",
            "Connection: close",
        ]
        if let contentRange {
            headers.append("Content-Range: \(contentRange)")
        }

        let headerString = headers.joined(separator: "\r\n") + "\r\n\r\n"
        guard let headerData = headerString.data(using: .utf8) else {
            return HTTPResponse(status: 500, body: "Internal Server Error")
        }
        var response = Data()
        response.append(headerData)
        if method == "GET" {
            response.append(bodyData)
        }

        return HTTPResponse(status: statusCode, data: response, retryAfterSeconds: nil)
    }

    private func logRangeServerRequest(
        id: Int,
        method: String,
        rangeHeader: String?,
        mediaStart: Int64,
        mediaEnd: Int64,
        length: Int
    ) {
        TorrentLog.info(
            "[RangeServer] ← REQUEST #\(id) method=\(method) range=\(rangeHeader ?? "none") mediaStart=\(mediaStart) mediaEnd=\(mediaEnd) length=\(length)"
        )
    }

    private func logRangeServerResponse(
        id: Int,
        statusCode: Int,
        servedBytes: Int,
        torrentOffset: Int64,
        wasReadable: Bool
    ) {
        TorrentLog.info(
            "[RangeServer] → RESPONSE #\(id) status=\(statusCode) servedBytes=\(servedBytes) torrentOffset=\(torrentOffset) readable=\(wasReadable)"
        )
    }

    private func logRangeServerAndReturn(
        id: Int,
        response: HTTPResponse,
        statusCode: Int,
        servedBytes: Int,
        torrentOffset: Int64,
        wasReadable: Bool
    ) -> HTTPResponse {
        logRangeServerResponse(
            id: id,
            statusCode: statusCode,
            servedBytes: servedBytes,
            torrentOffset: torrentOffset,
            wasReadable: wasReadable
        )
        return response
    }

    private func notifyPlayerRead(mediaOffset: Int64, length: Int) async {
        await pieceManager?.notePlayerRead(mediaOffset: mediaOffset, length: length)
        await onPlayerRead?(mediaOffset, length)
    }

    private func waitForReadableSpan(
        pieceStore: PieceStore,
        offset: Int64,
        length: Int,
        preferSuffix: Bool
    ) async -> (offset: Int64, length: Int)? {
        let attempts = Int(Self.bufferWaitSeconds * 10)
        for attempt in 0..<attempts {
            if Task.isCancelled {
                return nil
            }
            if let span = await pieceStore.readableSpan(
                offset: offset,
                length: length,
                preferSuffix: preferSuffix
            ) {
                if attempt > 0 {
                    TorrentLog.info(
                        "[HTTPRangeServer] Range ready after \(attempt * 100)ms — \(span.length) B @ \(span.offset) suffix=\(preferSuffix)"
                    )
                }
                return span
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return nil
            }
        }
        return nil
    }

    // MARK: - Virtual fast-start translation

    enum VirtualRangeResolution {
        /// Bytes served directly from the synthesized header (no disk wait).
        case syntheticHeaderBytes(data: Data)
        /// Bytes that map to actual mdat content in the on-disk torrent file.
        case rawTorrentBytes(torrentOffset: Int64, length: Int)
    }

    /// Translates a virtual-media range (what AVPlayer sees) into either an
    /// in-memory header slice or an absolute torrent-file offset.
    func resolveVirtualRange(mediaStart: Int64, length: Int) -> VirtualRangeResolution {
        guard let layout = remuxedLayout else {
            // No remux installed — serve raw torrent bytes as before.
            return .rawTorrentBytes(
                torrentOffset: streamByteOffset + mediaStart,
                length: length
            )
        }

        let headerLen = Int64(layout.syntheticHeader.count)
        let requestEnd = mediaStart + Int64(length)

        if mediaStart < headerLen {
            // Range falls (at least partially) in the synthesized header.
            // Serve only the header portion in this response; AVPlayer will issue
            // a follow-up range request for any remaining bytes.
            let end = min(requestEnd, headerLen)
            let from = layout.syntheticHeader.startIndex + Int(mediaStart)
            let to = layout.syntheticHeader.startIndex + Int(end)
            let slice = layout.syntheticHeader[from..<to]
            return .syntheticHeaderBytes(data: Data(slice))
        } else {
            // Range falls fully inside mdat — translate to original torrent offset.
            let mdatVirtualStart = mediaStart - headerLen
            let absoluteMdatTorrentOffset = streamByteOffset + layout.mdatContentTorrentOffset + mdatVirtualStart
            return .rawTorrentBytes(torrentOffset: absoluteMdatTorrentOffset, length: length)
        }
    }

    /// Reverse-translate a torrent offset back into the virtual-media coordinate
    /// space presented to AVPlayer. Used to set Content-Range correctly.
    func virtualMediaOffset(forTorrentOffset torrentOffset: Int64) -> Int64 {
        guard let layout = remuxedLayout else {
            return torrentOffset - streamByteOffset
        }
        let mdatTorrentOffset = streamByteOffset + layout.mdatContentTorrentOffset
        let mdatVirtualStart = Int64(layout.syntheticHeader.count)
        return mdatVirtualStart + (torrentOffset - mdatTorrentOffset)
    }

    /// Coalesces duplicate concurrent torrent reads. AVPlayer commonly fires
    /// 6–8 parallel range requests for the same byte window; without this
    /// each one would spin up its own 300-second `waitForReadable` loop and
    /// surface as a cascade of read timeouts.
    private func waitForTorrentRange(
        pieceStore: PieceStore,
        offset: Int64,
        length: Int
    ) async throws -> Data {
        let key = "\(offset):\(length)"

        if pendingRangeWaiters[key] != nil {
            return try await withCheckedThrowingContinuation { continuation in
                pendingRangeWaiters[key, default: []].append(continuation)
            }
        }

        pendingRangeWaiters[key] = []
        do {
            let data = try await readBytes(pieceStore: pieceStore, offset: offset, length: length)
            let waiters = pendingRangeWaiters.removeValue(forKey: key) ?? []
            for waiter in waiters { waiter.resume(returning: data) }
            return data
        } catch {
            let waiters = pendingRangeWaiters.removeValue(forKey: key) ?? []
            for waiter in waiters { waiter.resume(throwing: error) }
            throw error
        }
    }

    private func readBytes(pieceStore: PieceStore, offset: Int64, length: Int) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await pieceStore.read(offset: offset, length: length)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.readTimeoutSeconds))
                throw HTTPRangeReadTimeout()
            }
            guard let data = try await group.next() else {
                throw HTTPRangeReadTimeout()
            }
            group.cancelAll()
            return data
        }
    }

    private func sendResponse(connection: NWConnection, response: HTTPResponse) {
        connection.send(content: response.data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private struct HTTPRangeReadTimeout: Error {}

struct HTTPResponse {
    let status: Int
    let data: Data

    init(status: Int, body: String, retryAfterSeconds: Int? = nil) {
        self.status = status
        var headerLines = [
            "HTTP/1.1 \(status) \(HTTPResponse.statusMessage(for: status))",
            "Content-Length: \(body.count)",
            "Content-Type: text/plain",
            "Connection: close",
        ]
        if let retryAfterSeconds {
            headerLines.append("Retry-After: \(retryAfterSeconds)")
        }
        let raw = headerLines.joined(separator: "\r\n") + "\r\n\r\n" + body
        self.data = raw.data(using: .utf8) ?? Data()
    }

    init(status: Int, data: Data, retryAfterSeconds: Int? = nil) {
        self.status = status
        self.data = data
    }

    static func statusMessage(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        case 503: "Service Unavailable"
        case 500: "Internal Server Error"
        default: "Unknown"
        }
    }
}

public enum HTTPRangeServerError: Error, LocalizedError {
    case failedToStart

    public var errorDescription: String? {
        "Failed to start HTTP range server"
    }
}
