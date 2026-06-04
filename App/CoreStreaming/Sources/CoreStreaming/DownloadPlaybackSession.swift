import Foundation

public enum DownloadPlaybackError: Error, LocalizedError {
    case downloadNotActive
    case insufficientBuffer

    public var errorDescription: String? {
        switch self {
        case .downloadNotActive:
            "This download is not active. Resume it, then try Watch again."
        case .insufficientBuffer:
            "Not enough of the file is downloaded to play yet. Keep downloading, then try Watch again."
        }
    }
}

/// Serves loopback HTTP from an in-progress download's piece store (same path as torrent streaming).
@MainActor
public final class DownloadPlaybackSession {
    public let playbackURL: URL
    public let streamTarget: TorrentStreamTarget

    private let store: PieceStore
    private let manager: PieceManager
    private weak var engine: TorrentEngine?
    private let rangeServer: HTTPRangeServer

    init(
        playbackURL: URL,
        streamTarget: TorrentStreamTarget,
        store: PieceStore,
        manager: PieceManager,
        engine: TorrentEngine,
        rangeServer: HTTPRangeServer
    ) {
        self.playbackURL = playbackURL
        self.streamTarget = streamTarget
        self.store = store
        self.manager = manager
        self.engine = engine
        self.rangeServer = rangeServer
    }

    public func streamHeadContiguousBytes() async -> Int64 {
        await store.streamHeadContiguousBytes()
    }

    public func prioritizePlayback(atSeconds time: Double, durationSeconds: Double) async {
        guard durationSeconds.isFinite,
              durationSeconds > 0,
              time.isFinite,
              time >= 0
        else { return }

        let fraction = max(0, min(1, time / durationSeconds))
        let anchor = Int64(Double(streamTarget.byteLength) * fraction)
        let window = Int64(32 * 1024 * 1024)
        let remaining = max(0, streamTarget.byteLength - anchor)
        let readLength = min(Int(window), Int(remaining))
        if readLength > 0 {
            await manager.markUserSeekPlayback(atMediaOffset: anchor, length: readLength)
        }
        engine?.refreshDownloadPriorities()
    }

    public func readableMediaTimeRanges(durationSeconds: Double) async -> [ClosedRange<Double>] {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return [] }
        let mediaLength = streamTarget.byteLength
        guard mediaLength > 0 else { return [] }

        let byteRanges = await store.accumulatedReadableMediaByteRanges()
        return byteRanges.compactMap { byteRange in
            let start = Double(byteRange.lowerBound) / Double(mediaLength) * durationSeconds
            let end = Double(byteRange.upperBound + 1) / Double(mediaLength) * durationSeconds
            guard end.isFinite, start.isFinite, end > start else { return nil }
            return max(0, start)...min(durationSeconds, end)
        }
    }

    public func hasReadablePlaybackData(atSeconds time: Double, durationSeconds: Double) async -> Bool {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return false }
        let fraction = max(0, min(1, time / durationSeconds))
        let mediaOffset = Int64(Double(streamTarget.byteLength) * fraction)
        let torrentOffset = streamTarget.byteOffset + max(0, min(streamTarget.byteLength, mediaOffset))
        let requiredBytes = min(2 * 1024 * 1024, Int(max(0, streamTarget.byteLength - mediaOffset)))
        guard requiredBytes > 0,
              let span = await store.readableSpan(
                  offset: torrentOffset,
                  length: requiredBytes,
                  preferSuffix: false
              )
        else { return false }
        return span.offset <= torrentOffset
            && span.offset + Int64(span.length) >= torrentOffset + Int64(requiredBytes)
    }

    public func stop() async {
        await rangeServer.stop()
    }
}
