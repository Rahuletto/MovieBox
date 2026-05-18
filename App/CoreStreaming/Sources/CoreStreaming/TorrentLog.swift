import Foundation

/// BitTorrent / P2P logging. Disabled by default — set `isVerbose = true` when debugging peers.
enum TorrentLog {
    static let isVerbose = false

    static func debug(_ message: String) {
        guard isVerbose else { return }
        NSLog(message)
    }

    static func info(_ message: String) {
        guard isVerbose else { return }
        NSLog(message)
    }

    /// Real failures only (I/O, listener, hash verification after retries).
    static func warn(_ message: String) {
        NSLog(message)
    }
}
