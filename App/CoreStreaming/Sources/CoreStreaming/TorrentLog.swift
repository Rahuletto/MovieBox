import CoreStorage
import Foundation

/// BitTorrent / P2P logging to `moviebox.log`. Peer chatter is gated; playback path is always logged.
enum TorrentLog {
    /// Verbose peer connect / tracker spam (off by default).
    static let isVerbose = false

    static func debug(_ message: String) {
        guard isVerbose else { return }
        MovieBoxFileLogger.log(.debug, category: "torrent", message)
    }

    /// Metadata fetch, engine start, buffer milestones — always on file.
    static func info(_ message: String) {
        MovieBoxFileLogger.log(.info, category: "torrent", message)
    }

    static func warn(_ message: String) {
        MovieBoxFileLogger.log(.warn, category: "torrent", message)
    }

    static func error(_ message: String) {
        MovieBoxFileLogger.log(.error, category: "torrent", message)
    }
}
