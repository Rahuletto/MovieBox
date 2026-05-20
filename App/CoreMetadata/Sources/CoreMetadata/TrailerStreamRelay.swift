import Foundation
import Network

/// Local HTTP server that forwards Range requests to a remote trailer URL with headers AVPlayer omits.
@MainActor
public final class TrailerStreamRelay {
    public static let shared = TrailerStreamRelay()

    private var listener: NWListener?
    private var upstreamURL: URL?
    private let session: URLSession

    public private(set) var port: UInt16 = 0

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config)
    }

    /// Proxies `upstream` at `http://127.0.0.1:<port>/` for AVPlayer.
    public func publish(upstream: URL) async throws -> URL {
        await stop()
        upstreamURL = upstream

        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port.any)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                await self?.handle(connection: connection)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    
                    // Already resumed (port was set)
                    guard self.port == 0 else { return }
                    
                    switch state {
                    case .ready:
                        guard let nwPort = listener.port else { return }
                        self.port = nwPort.rawValue
                        if let url = URL(string: "http://127.0.0.1:\(nwPort.rawValue)/stream") {
                            continuation.resume(returning: url)
                        } else {
                            continuation.resume(throwing: TrailerStreamRelayError.failedToStart)
                        }
                    case .failed(let error):
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
        upstreamURL = nil
        port = 0
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) async {
        guard upstreamURL != nil else {
            connection.cancel()
            return
        }

        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
                    guard let self else {
                        connection.cancel()
                        return
                    }
                    if error != nil {
                        connection.cancel()
                        return
                    }
                    guard let data, let request = String(data: data, encoding: .utf8) else {
                        connection.cancel()
                        return
                    }
                    Task { @MainActor in
                        await self.respond(to: request, connection: connection)
                    }
                }
            }
        }
        connection.start(queue: .main)
    }

    private func respond(to request: String, connection: NWConnection) async {
        guard let upstreamURL else {
            connection.cancel()
            return
        }

        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            send(connection: connection, status: 400, headers: [:], body: Data())
            return
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, parts[0].uppercased() == "GET" || parts[0].uppercased() == "HEAD" else {
            send(connection: connection, status: 405, headers: [:], body: Data())
            return
        }

        let method = parts[0].uppercased()
        var upstreamRequest = URLRequest(url: upstreamURL)
        upstreamRequest.httpMethod = method
        applyUpstreamHeaders(&upstreamRequest)

        if let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            let value = rangeLine.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
            upstreamRequest.setValue(String(value), forHTTPHeaderField: "Range")
        }

        do {
            let (data, response) = try await session.data(for: upstreamRequest)
            guard let http = response as? HTTPURLResponse else {
                send(connection: connection, status: 502, headers: [:], body: Data())
                return
            }

            var headers: [String: String] = [:]
            if let contentType = http.value(forHTTPHeaderField: "Content-Type") {
                headers["Content-Type"] = contentType
            } else {
                headers["Content-Type"] = "video/mp4"
            }
            if let contentRange = http.value(forHTTPHeaderField: "Content-Range") {
                headers["Content-Range"] = contentRange
            }
            if let acceptRanges = http.value(forHTTPHeaderField: "Accept-Ranges") {
                headers["Accept-Ranges"] = acceptRanges
            } else {
                headers["Accept-Ranges"] = "bytes"
            }
            let contentLength = http.value(forHTTPHeaderField: "Content-Length")
            if let contentLength {
                headers["Content-Length"] = contentLength
            }

            let body = method == "HEAD" ? Data() : data
            send(connection: connection, status: http.statusCode, headers: headers, body: body)
        } catch {
            send(connection: connection, status: 502, headers: ["Content-Type": "text/plain"], body: Data("Bad Gateway".utf8))
        }
    }

    private func applyUpstreamHeaders(_ request: inout URLRequest) {
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
    }

    private func send(connection: NWConnection, status: Int, headers: [String: String], body: Data) {
        var response = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        response += "Connection: close\r\n\r\n"
        var data = Data(response.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        case 502: "Bad Gateway"
        default: "Error"
        }
    }
}

public enum TrailerStreamRelayError: Error {
    case failedToStart
}
