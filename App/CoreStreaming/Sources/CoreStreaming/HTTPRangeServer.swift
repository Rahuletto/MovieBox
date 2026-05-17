import Foundation
import Network

// MARK: - HTTP Range Server

@MainActor
public final class HTTPRangeServer {
    public private(set) var port: UInt16 = 0
    public private(set) var isRunning = false

    private var listener: NWListener?
    private var pieceStore: PieceStore?

    public init() {}

    public func start(pieceStore: PieceStore, preferredPort: UInt16 = 0) async throws -> URL {
        self.pieceStore = pieceStore

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
                    NSLog("HTTPRangeServer failed: \(error)")
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
    }

    private func handleConnection(_ connection: NWConnection) async {
        guard let pieceStore else {
            connection.cancel()
            return
        }

        connection.stateUpdateHandler = { state in
            if case .ready = state {
                Task { @MainActor in
                    await self.receiveHTTPRequest(connection: connection, pieceStore: pieceStore)
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receiveHTTPRequest(connection: NWConnection, pieceStore: PieceStore) async {
        var buffer = Data()

        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            guard let data, !isComplete, error == nil else {
                connection.cancel()
                return
            }

            buffer.append(data)

            if let requestEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer[..<requestEnd.lowerBound]
                if let request = String(data: headerData, encoding: .utf8) {
                    Task { @MainActor in
                        let response = await self.handleRequest(request, pieceStore: pieceStore)
                        self.sendResponse(connection: connection, response: response)
                    }
                }
            } else {
                Task { @MainActor in
                    await self.receiveHTTPRequest(connection: connection, pieceStore: pieceStore)
                }
            }
        }
    }

    private func handleRequest(_ request: String, pieceStore: PieceStore) async -> HTTPResponse {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return HTTPResponse(status: 400, body: "Bad Request")
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            return HTTPResponse(status: 405, body: "Method Not Allowed")
        }

        let totalSize = pieceStore.totalSize

        var statusCode = 200
        var bodyData: Data = Data()
        var contentRange: String?
        var contentLength = totalSize

        if let rangeHeader = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            let rangeParts = rangeHeader.components(separatedBy: "=")
            if rangeParts.count == 2 {
                let byteRange = rangeParts[1]
                let rangeComponents = byteRange.components(separatedBy: "-")
                if let startStr = rangeComponents.first, let start = Int64(startStr) {
                    let end: Int64
                    if let endStr = rangeComponents.last, !endStr.isEmpty, let parsedEnd = Int64(endStr) {
                        end = parsedEnd
                    } else {
                        end = totalSize - 1
                    }

                    let length = Int(end - start + 1)
                    do {
                        bodyData = try await pieceStore.read(offset: start, length: length)
                        statusCode = 206
                        contentRange = "bytes \(start)-\(end)/\(totalSize)"
                        contentLength = Int64(bodyData.count)
                    } catch {
                        return HTTPResponse(status: 500, body: "Internal Server Error")
                    }
                }
            }
        } else {
            do {
                let length = min(1024 * 1024, Int(totalSize))
                bodyData = try await pieceStore.read(offset: 0, length: length)
                contentLength = Int64(bodyData.count)
            } catch {
                return HTTPResponse(status: 500, body: "Internal Server Error")
            }
        }

        var headers = [
            "HTTP/1.1 \(statusCode) \(HTTPResponse.statusMessage(for: statusCode))",
            "Content-Type: video/mp4",
            "Content-Length: \(contentLength)",
            "Accept-Ranges: bytes",
            "Connection: close",
            ""
        ]

        if let contentRange {
            headers.insert("Content-Range: \(contentRange)", at: headers.count - 1)
        }

        let headerString = headers.joined(separator: "\r\n")
        let headerData = headerString.data(using: .utf8)!

        var response = Data()
        response.append(headerData)
        response.append(bodyData)

        return HTTPResponse(status: statusCode, data: response)
    }

    private func sendResponse(connection: NWConnection, response: HTTPResponse) {
        connection.send(content: response.data, completion: .contentProcessed { error in
            if error != nil {
                NSLog("HTTPRangeServer send error: \(String(describing: error))")
            }
            connection.cancel()
        })
    }
}

private struct HTTPResponse {
    let status: Int
    let data: Data

    init(status: Int, body: String) {
        self.status = status
        self.data = "HTTP/1.1 \(status) \(HTTPResponse.statusMessage(for: status))\r\nContent-Length: \(body.count)\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n\(body)".data(using: .utf8)!
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
