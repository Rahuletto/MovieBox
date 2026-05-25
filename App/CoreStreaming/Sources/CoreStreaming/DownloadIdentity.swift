import Foundation

/// Resolved info hash and tracker list for starting a torrent download.
public struct DownloadIdentity: Sendable {
    public let infoHash: String
    public let magnetTrackers: [String]

    public init(infoHash: String, magnetTrackers: [String]) {
        self.infoHash = infoHash
        self.magnetTrackers = magnetTrackers
    }

    /// Prefers a parsed magnet link (correct base32 → hex); falls back to a stored hash from search APIs.
    public static func resolve(magnetURI: String, storedInfoHash: String? = nil) -> DownloadIdentity? {
        if let magnet = MagnetURI(from: magnetURI) {
            return DownloadIdentity(infoHash: magnet.infoHash, magnetTrackers: magnet.trackers)
        }
        if let stored = storedInfoHash, let hash = MagnetURI.normalizeInfoHash(stored) {
            return DownloadIdentity(infoHash: hash, magnetTrackers: [])
        }
        return nil
    }
}
