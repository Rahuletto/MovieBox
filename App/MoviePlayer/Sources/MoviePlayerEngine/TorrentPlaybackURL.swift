import Foundation

/// Custom AVPlayer resource-loader schemes for torrent streaming.
public enum TorrentPlaybackURL {
    public static let activeScheme = "mbtorrenthttps"
    public static let legacyScheme = "mbtorrent"

    public static func isTorrentPlayback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == activeScheme || scheme == legacyScheme
    }
}
