import CoreStreaming
import Foundation

/// Live buffering state for a single torrent row on the detail page.
public struct TorrentRowBufferingSnapshot: Equatable, Sendable {
    public var progress: Double
    public var phase: String
    public var detail: String

    public init(progress: Double, phase: String, detail: String) {
        self.progress = progress
        self.phase = phase
        self.detail = detail
    }

    public static let starting = TorrentRowBufferingSnapshot(
        progress: 0.04,
        phase: "Starting…",
        detail: "Loading torrent metadata"
    )
}

public extension TorrentStreamSession {
    @MainActor
    func rowBufferingSnapshot() async -> TorrentRowBufferingSnapshot {
        let metrics = await rowBufferingMetrics()
        return TorrentRowBufferingSnapshot(metrics: metrics)
    }
}

private extension TorrentRowBufferingSnapshot {
    init(metrics: StreamRowBufferingMetrics) {
        if let failedMessage = metrics.failedMessage {
            self.init(progress: 0, phase: "Failed", detail: failedMessage)
            return
        }

        if metrics.isReady {
            self.init(progress: 1, phase: "Opening player…", detail: "Starting playback")
            return
        }

        if metrics.isPreparing {
            self.init(
                progress: max(0.04, metrics.progress),
                phase: "Starting stream…",
                detail: "Preparing peers and metadata"
            )
            return
        }

        let headKB = metrics.verifiedHeadBytes / 1024
        let minHeadKB = StreamPlaybackThreshold.minimumHeadBytes / 1024
        let speedKB = Int(max(0, metrics.downloadSpeed / 1024))

        var phase = "Buffering…"
        if metrics.peerCount == 0 {
            phase = "Finding peers…"
        } else if metrics.transferringPeerCount == 0 {
            phase = "Waiting for data…"
        } else if headKB < minHeadKB {
            phase = "Downloading start…"
        } else if metrics.needsTailProbe, metrics.tailVerified < metrics.tailTotal {
            phase = "Loading \(metrics.indexProbeLabel)…"
        } else if metrics.progress < 0.85 {
            phase = "Building buffer…"
        } else {
            phase = "Almost ready…"
        }

        var detailParts: [String] = []
        if metrics.peerCount > 0 {
            detailParts.append("\(metrics.peerCount) peers")
        }
        if metrics.transferringPeerCount > 0 {
            detailParts.append("\(metrics.transferringPeerCount) sending")
        }
        if speedKB > 0 {
            detailParts.append("\(speedKB) KB/s")
        }
        if headKB > 0 {
            detailParts.append("\(headKB)/\(minHeadKB) KB head")
        }
        if metrics.needsTailProbe, metrics.tailVerified < metrics.tailTotal {
            detailParts.append("\(metrics.tailVerified)/\(metrics.tailTotal) index pieces")
        }

        self.init(
            progress: min(0.98, max(0.05, metrics.progress)),
            phase: phase,
            detail: detailParts.joined(separator: " · ")
        )
    }
}
