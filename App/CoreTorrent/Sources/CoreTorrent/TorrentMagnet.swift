import Foundation

public enum TorrentMagnet {
    public static let defaultTrackers = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://explodie.org:6969/announce",
        "udp://tracker.openbittorrent.com:6969/announce",
    ]

    /// Builds a magnet link with tracker announces so metadata and peer discovery can succeed.
    public static func build(infoHash: String, displayName: String, extraTrackers: [String] = []) -> String {
        let hash = infoHash
            .replacingOccurrences(of: "urn:btih:", with: "", options: .caseInsensitive)
            .lowercased()
        let encodedName = displayName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? displayName

        var trackers = extraTrackers
        for tracker in defaultTrackers where !trackers.contains(tracker) {
            trackers.append(tracker)
        }

        let trackerParams = trackers
            .map { "&tr=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0)" }
            .joined()

        return "magnet:?xt=urn:btih:\(hash)&dn=\(encodedName)\(trackerParams)"
    }
}
