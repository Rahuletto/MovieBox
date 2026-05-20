import CorePlayer
import CoreStreaming
import Foundation

public extension TorrentStreamSession {
    @MainActor
    func waitForPlayback(timeout: TimeInterval = 180) async {
        PlaybackLog.log("Waiting for torrent buffer…")
        let deadline = Date().addingTimeInterval(timeout)
        var lastHeartbeat = Date.distantPast

        while !Task.isCancelled, Date() < deadline {
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

        if case .ready = state {
            PlaybackLog.log("Stream settled — \(stateLabel)")
            return
        }
        if case .failed = state {
            PlaybackLog.log("Stream settled — \(stateLabel)")
            return
        }
        if case .cancelled = state {
            PlaybackLog.log("Stream settled — cancelled")
            return
        }

        await failWithTimeout()
        PlaybackLog.log("Stream settled — \(stateLabel)")
    }
}
