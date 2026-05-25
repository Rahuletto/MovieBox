import CoreStorage
import Foundation
import Network

/// Serves a remux HLS output directory over loopback HTTP so AVPlayer can poll an EVENT playlist.
@MainActor
public final class HLSCacheServer {
    public private(set) var port: UInt16 = 0
    public private(set) var isRunning = false
    public var playlistURL: URL?

    private var listener: NWListener?
    private var rootDirectory: URL?

    public init() {}

    public func start(rootDirectory: URL) async throws -> URL {
        stop()
        self.rootDirectory = rootDirectory

        let parameters = NWParameters.tcp
        listener = try NWListener(using: parameters, on: .any)

        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    self?.isRunning = true
                case .failed(let error):
                    self?.isRunning = false
                    MoviePlayerLog.warn("[HLSCacheServer] Listener failed: \(error)")
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
        try await Task.sleep(for: .milliseconds(200))

        guard let port = listener?.port else {
            throw HLSCacheServerError.failedToStart
        }
        self.port = port.rawValue
        guard let url = URL(string: "http://127.0.0.1:\(port)/stream.m3u8") else {
            throw HLSCacheServerError.failedToStart
        }
        playlistURL = url
        MoviePlayerLog.info("[HLSCacheServer] listening port=\(port) dir=\(rootDirectory.path)")
        return url
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        port = 0
        playlistURL = nil
        rootDirectory = nil
    }

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .main)
        var requestBuffer = Data()

        for _ in 0..<256 {
            let chunk: Data? = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                    continuation.resume(returning: data)
                }
            }
            guard let chunk, !chunk.isEmpty else { break }
            requestBuffer.append(chunk)
            if requestBuffer.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }

        guard let requestText = String(data: requestBuffer, encoding: .utf8) else {
            connection.cancel()
            return
        }
        let lines = requestText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            await sendResponse(connection, status: 405, headers: [:], body: Data())
            connection.cancel()
            return
        }

        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath
        let fileName = (path as NSString).lastPathComponent
        guard !fileName.isEmpty, !fileName.contains("..") else {
            await sendResponse(connection, status: 404, headers: [:], body: Data())
            connection.cancel()
            return
        }

        guard let rootDirectory else {
            await sendResponse(connection, status: 503, headers: [:], body: Data())
            connection.cancel()
            return
        }

        let fileURL = rootDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            await sendResponse(connection, status: 404, headers: [:], body: Data())
            connection.cancel()
            return
        }

        if fileName == "stream.m3u8" {
            RemuxService.normalizeStreamingPlaylist(at: fileURL)
        }

        guard let body = try? Data(contentsOf: fileURL) else {
            await sendResponse(connection, status: 500, headers: [:], body: Data())
            connection.cancel()
            return
        }

        var headers = [
            "Content-Type": contentType(for: fileName),
            "Accept-Ranges": "bytes",
            "Connection": "close",
        ]
        if fileName.hasSuffix(".m3u8") {
            headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        }

        await sendResponse(connection, status: 200, headers: headers, body: body)
        connection.cancel()
    }

    private func contentType(for fileName: String) -> String {
        switch fileName.lowercased() {
        case "stream.m3u8":
            "application/vnd.apple.mpegurl"
        case let name where name.hasSuffix(".m4s"), let name where name.hasSuffix(".mp4"):
            "video/mp4"
        case let name where name.hasSuffix(".ts"):
            "video/mp2t"
        default:
            "application/octet-stream"
        }
    }

    private func sendResponse(
        _ connection: NWConnection,
        status: Int,
        headers: [String: String],
        body: Data
    ) async {
        var lines = ["HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))"]
        for (key, value) in headers {
            lines.append("\(key): \(value)")
        }
        lines.append("Content-Length: \(body.count)")
        let headerData = (lines.joined(separator: "\r\n") + "\r\n\r\n").data(using: .utf8) ?? Data()
        var response = Data()
        response.append(headerData)
        response.append(body)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: response, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}

public enum HLSCacheServerError: Error, LocalizedError {
    case failedToStart

    public var errorDescription: String? {
        switch self {
        case .failedToStart:
            "Failed to start HLS cache server."
        }
    }
}
