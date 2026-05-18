import Foundation

/// Hot-path logging is disabled by default — enable for debugging P2P issues.
enum TorrentLog {
    static let isVerbose = false

    static func debug(_ message: String) {
        guard isVerbose else { return }
        NSLog(message)
    }

    static func info(_ message: String) {
        NSLog(message)
    }
}
