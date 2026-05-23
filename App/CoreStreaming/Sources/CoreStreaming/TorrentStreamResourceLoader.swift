import AVFoundation
import Foundation

/// Serves torrent file bytes to AVPlayer without loopback HTTP (FINDINGS Tier 3).
public final class TorrentStreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let pieceStore: PieceStore
    private let streamByteOffset: Int64
    private let streamByteLength: Int64
    private let contentType: String
    private let avContentType: String
    private let pieceManager: PieceManager
    private let onPlayerRead: @Sendable (Int64, Int) async -> Void
    private let workQueue = DispatchQueue(label: "com.marban.moviebox.torrent-resource-loader")
    private var isInvalidated = false

    init(
        pieceStore: PieceStore,
        streamTarget: TorrentStreamTarget,
        pieceManager: PieceManager,
        onPlayerRead: @escaping @Sendable (Int64, Int) async -> Void
    ) {
        self.pieceStore = pieceStore
        self.streamByteOffset = streamTarget.byteOffset
        self.streamByteLength = streamTarget.byteLength
        self.contentType = streamTarget.contentType
        self.avContentType = Self.uniformTypeIdentifier(for: streamTarget.contentType)
        self.pieceManager = pieceManager
        self.onPlayerRead = onPlayerRead
    }

    func invalidate() {
        isInvalidated = true
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !isInvalidated else { return false }
        // #region agent log
        let hasInfo = loadingRequest.contentInformationRequest != nil
        let dr = loadingRequest.dataRequest
        TorrentLog.info(
            "[TorrentResourceLoader] shouldWait contentInfo=\(hasInfo) offset=\(dr?.requestedOffset ?? -1) length=\(dr?.requestedLength ?? -1)"
        )
        AgentDebugLog.write(
            hypothesisId: "H2",
            location: "TorrentStreamResourceLoader.swift:shouldWait",
            message: "resourceLoader shouldWait",
            data: [
                "hasContentInfo": hasInfo,
                "dataOffset": dr?.requestedOffset ?? -1,
                "dataLength": dr?.requestedLength ?? -1,
            ]
        )
        // #endregion
        workQueue.async { [weak self] in
            self?.fill(loadingRequest)
        }
        return true
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        workQueue.async {
            loadingRequest.finishLoading()
        }
    }

    private func fill(_ loadingRequest: AVAssetResourceLoadingRequest) {
        if isInvalidated {
            loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
            return
        }

        if let infoRequest = loadingRequest.contentInformationRequest {
            infoRequest.contentType = avContentType
            infoRequest.contentLength = streamByteLength
            infoRequest.isByteRangeAccessSupported = true

            // AVFoundation probes with a 2-byte data request; never respond with bytes (Jared Sinclair).
            if let dataRequest = loadingRequest.dataRequest,
               dataRequest.requestedOffset == 0,
               dataRequest.requestedLength <= 2,
               !dataRequest.requestsAllDataToEndOfResource {
                // #region agent log
                AgentDebugLog.write(
                    hypothesisId: "H3",
                    location: "TorrentStreamResourceLoader.swift:contentProbe",
                    message: "content info probe finished without data",
                    data: ["avContentType": avContentType, "mime": contentType]
                )
                // #endregion
                loadingRequest.finishLoading()
                return
            }
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return
        }

        let mediaOffset = dataRequest.requestedOffset
        let requestedLength = Int(dataRequest.requestedLength)
        guard requestedLength > 0, mediaOffset >= 0, mediaOffset < streamByteLength else {
            loadingRequest.finishLoading()
            return
        }

        let clampedLength = min(requestedLength, Int(streamByteLength - mediaOffset))
        let torrentOffset = streamByteOffset + mediaOffset
        let preferSuffix = mediaOffset + Int64(clampedLength) >= streamByteLength - 1024

        Task {
            await onPlayerRead(mediaOffset, clampedLength)

            guard let span = await waitForReadableSpan(
                offset: torrentOffset,
                length: clampedLength,
                preferSuffix: preferSuffix
            ) else {
                workQueue.async {
                    loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
                }
                return
            }

            do {
                let data = try await readFullSpan(offset: span.offset, length: span.length)
                workQueue.async { [weak self] in
                    guard let self, !self.isInvalidated else {
                        loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
                        return
                    }
                    let serveStart = span.offset - self.streamByteOffset
                    let skip = Int(max(0, mediaOffset - serveStart))
                    let slice = data.dropFirst(skip).prefix(clampedLength)
                    dataRequest.respond(with: Data(slice))
                    loadingRequest.finishLoading()
                    // #region agent log
                    AgentDebugLog.write(
                        hypothesisId: "H4",
                        location: "TorrentStreamResourceLoader.swift:respond",
                        message: "responded to data request",
                        data: [
                            "mediaOffset": mediaOffset,
                            "bytes": slice.count,
                        ]
                    )
                    // #endregion
                }
            } catch {
                workQueue.async {
                    loadingRequest.finishLoading(with: error as NSError)
                }
            }
        }
    }

    private func waitForReadableSpan(
        offset: Int64,
        length: Int,
        preferSuffix: Bool
    ) async -> (offset: Int64, length: Int)? {
        var attempt = 0
        while !Task.isCancelled, !isInvalidated {
            if let span = await pieceStore.readableSpan(offset: offset, length: length, preferSuffix: preferSuffix) {
                return span
            }
            attempt += 1
            if attempt % 100 == 0 {
                TorrentLog.info(
                    "[TorrentResourceLoader] waiting for \(length) B @ torrent \(offset) (\(attempt / 10)s)"
                )
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func readFullSpan(offset: Int64, length: Int) async throws -> Data {
        var waitLoops = 0
        while !Task.isCancelled, !isInvalidated {
            if let data = try? await pieceStore.read(offset: offset, length: length), data.count == length {
                return data
            }
            waitLoops += 1
            if waitLoops % 100 == 0 {
                TorrentLog.info("[TorrentResourceLoader] buffering read @ \(offset) need \(length) B")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CancellationError()
    }

    private static func uniformTypeIdentifier(for mime: String) -> String {
        let lower = mime.lowercased()
        if lower.contains("matroska") { return "org.matroska.mkv" }
        if lower.contains("webm") { return "org.webmproject.webm" }
        if lower.contains("quicktime") { return "com.apple.quicktime-movie" }
        return "public.mpeg-4"
    }
}
