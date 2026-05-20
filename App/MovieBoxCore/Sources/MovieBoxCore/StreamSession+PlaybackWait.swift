import CorePlayer
import CoreStreaming
import Foundation

public extension TorrentStreamSession {
    /// Waits until the stream reaches a terminal state (.ready, .failed, or .cancelled).
    /// The `timeout` parameter is ignored — the session's internal bufferingWatchdog
    /// already calculates the correct deadline (90s + 18s per tail piece for MP4s) and
    /// calls failWithTimeout() when needed. Relying on a fixed 180s deadline here was
    /// causing the session to be killed seconds before the tail pieces arrived.
    @MainActor
    func waitForPlayback(timeout: TimeInterval = 180) async {
        PlaybackLog.log("Waiting for torrent buffer…")
        var lastHeartbeat = Date.distantPast

        while !Task.isCancelled {
            switch state {
            case .ready, .failed, .cancelled:
                PlaybackLog.log("Stream settled — \(stateLabel)")
                return
            default:
                break
            }

            if Date().timeIntervalSince(lastHeartbeat) >= 5 {
                lastHeartbeat = Date()
                let verifiedKB = await verifiedHeadBytes() / 1024
                PlaybackLog.log(
                    "…still buffering — \(stateLabel), \(verifiedKB) KB verified head, \(peerCount) live peers (\(transferringPeerCount) transferring, indexer swarm: \(swarmSeeders) seeders), \(Int(downloadSpeed / 1024)) KB/s"
                )
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        PlaybackLog.log("Stream settled — \(stateLabel)")
    }
}
