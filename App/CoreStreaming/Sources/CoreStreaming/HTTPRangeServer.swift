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
    private var streamByteOffset: Int64 = 0
    private var streamByteLength: Int64 = 0
    private var contentType = "application/octet-stream"

    private static let maxRangeBytes = 2 * 1024 * 1024

    public init() {}

    /// Configures stream byte mapping without starting the TCP listener (unit tests).
    func configureForTests(pieceStore: PieceStore, streamTarget: TorrentStreamTarget) {
        self.pieceStore = pieceStore
        streamByteOffset = streamTarget.byteOffset
        streamByteLength = streamTarget.byteLength
        contentType = streamTarget.contentType
    }

    public func start(
        pieceStore: PieceStore,
        streamTarget: TorrentStreamTarget,
        preferredPort: UInt16 = 0
    ) async throws -> URL {
        self.pieceStore = pieceStore
        self.streamByteOffset = streamTarget.byteOffset
        self.streamByteLength = streamTarget.byteLength
        self.contentType = streamTarget.contentType

        let parameters = NWParameters.tcp
        let nwPort: NWEndpoint.Port
        if preferredPort > 0 {
            nwPort = NWEndpoint.Port(rawValue: preferredPort)!
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

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let port = self.listener?.port else {
                    continuation.resume(throwing: HTTPRangeServerError.failedToStart)
                    return
                }
                self.port = port.rawValue
                if let url = URL(string: "http://127.0.0.1:\(port)/stream") {
                    TorrentLog.info(
                        "[HTTPRangeServer] listening on port \(port.rawValue) — \(MovieBoxFileLogger.redactURL(url)) length=\(self.streamByteLength) offset=\(self.streamByteOffset)"
                    )
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: HTTPRangeServerError.failedToStart)
                }
            }
        }
    }

    public func stop() async {
        isRunning = false
        listener?.cancel()
        listener = nil
        pieceStore = nil
    }

    private func handleConnection(_ connection: NWConnection) async {
        guard let pieceStore else {
            connection.cancel()
            return
        }

        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                Task { @MainActor in
                    self?.receiveHTTPRequest(connection: connection, pieceStore: pieceStore)
                }
            }
        }
        connection.start(queue: .main)
    }

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

            if let requestEnd = requestBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = requestBuffer[..<requestEnd.lowerBound]
                guard let request = String(data: headerData, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                Task { @MainActor in
                    let response = await self.handleRequest(request, pieceStore: pieceStore)
                    self.sendResponse(connection: connection, response: response)
                }
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            Task { @MainActor in
                self.receiveHTTPRequest(connection: connection, pieceStore: pieceStore, buffer: requestBuffer)
            }
        }
    }

    func handleRequest(_ request: String, pieceStore: PieceStore) async -> HTTPResponse {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return HTTPResponse(status: 400, body: "Bad Request")
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            return HTTPResponse(status: 405, body: "Method Not Allowed")
        }

        let mediaLength = streamByteLength

        var statusCode = 200
        var bodyData = Data()
        var contentRange: String?
        var contentLength = mediaLength

        if let rangeHeader = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            let rangeParts = rangeHeader.components(separatedBy: "=")
            if rangeParts.count == 2 {
                let byteRange = rangeParts[1]
                let rangeComponents = byteRange.components(separatedBy: "-")
                if let startStr = rangeComponents.first, let mediaStart = Int64(startStr) {
                    let mediaEnd: Int64
                    if let endStr = rangeComponents.last, !endStr.isEmpty, let parsedEnd = Int64(endStr) {
                        mediaEnd = min(parsedEnd, mediaLength - 1)
                    } else {
                        mediaEnd = mediaLength - 1
                    }

                    guard mediaStart < mediaLength, mediaEnd >= mediaStart else {
                        return HTTPResponse(status: 416, body: "Range Not Satisfiable")
                    }

                    let span = mediaEnd &- mediaStart
                    let spanPlusOne = span &+ 1
                    guard spanPlusOne > 0, spanPlusOne <= Int64(Self.maxRangeBytes) else {
                        return HTTPResponse(status: 416, body: "Range Not Satisfiable")
                    }
                    var length = Int(spanPlusOne)
                    length = min(length, Self.maxRangeBytes)
                    let torrentOffset = streamByteOffset + mediaStart

                    do {
                        bodyData = try await pieceStore.read(offset: torrentOffset, length: length)
                        let servedEnd = mediaStart + Int64(bodyData.count) - 1
                        statusCode = 206
                        contentRange = "bytes \(mediaStart)-\(servedEnd)/\(mediaLength)"
                        contentLength = Int64(bodyData.count)
                    } catch {
                        TorrentLog.warn("[HTTPRangeServer] Range read failed: \(error.localizedDescription)")
                        return HTTPResponse(status: 500, body: "Internal Server Error")
                    }
                }
            }
        } else {
            let headAvailable = await pieceStore.streamHeadContiguousBytes()
            let length = min(512 * 1024, Int(mediaLength), Int(headAvailable))
            guard length > 0 else {
                return HTTPResponse(status: 503, body: "Buffering")
            }
            do {
                bodyData = try await pieceStore.read(offset: streamByteOffset, length: length)
                contentLength = Int64(bodyData.count)
            } catch {
                return HTTPResponse(status: 500, body: "Internal Server Error")
            }
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
        response.append(bodyData)

        return HTTPResponse(status: statusCode, data: response)
    }

    private func sendResponse(connection: NWConnection, response: HTTPResponse) {
        connection.send(content: response.data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

struct HTTPResponse {
    let status: Int
    let data: Data

    init(status: Int, body: String) {
        self.status = status
        let raw = "HTTP/1.1 \(status) \(HTTPResponse.statusMessage(for: status))\r\nContent-Length: \(body.count)\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n\(body)"
        self.data = raw.data(using: .utf8) ?? Data()
    }

    init(status: Int, data: Data) {
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
