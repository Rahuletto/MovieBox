import Foundation

public enum TorrentMagnet {
    public static let defaultTrackers = [
        "https://tracker.zhuqiy.com:443/announce",
        "https://tracker.yemekyedim.com:443/announce",
        "https://tracker.pmman.tech:443/announce",
        "https://tracker.nekomi.cn:443/announce",
        "https://tracker.moeking.me:443/announce",
        "https://tracker.leechshield.link:443/announce",
        "https://tracker.bt4g.com:443/announce",
        "https://tr.nyacat.pw:443/announce",
        "https://torrents.tmtime.dev:443/announce",
        "https://pybittrack.retiolus.net:443/announce",
        "https://open.ftorrent.com:443/announce",
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://explodie.org:6969/announce",
        "udp://tracker.openbittorrent.com:6969/announce",
        "http://tracker.opentrackr.org:1337/announce",
        "http://tracker2.dler.org:80/announce",
        "http://tracker.sbsub.com:2710/announce",
        "http://tracker.qu.ax:6969/announce",
        "http://open.trackerlist.xyz:80/announce",
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
