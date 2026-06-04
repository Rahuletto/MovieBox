import CoreStreaming
import CoreTorrent
import Foundation

public enum StreamFilePlaybackSupport {
    public static func torrentResult(
        displayTitle: String,
        metadata: TorrentMetadata
    ) -> TorrentResult {
        let target = TorrentStreamTarget.selectPrimary(from: metadata)
        let hash = metadata.infoHash.lowercased()
        return TorrentResult(
            title: displayTitle,
            magnetURI: "magnet:?xt=urn:btih:\(hash)",
            quality: .p1080,
            hdrType: nil,
            codec: .h264,
            audioFormat: nil,
            source: .webrip,
            sizeBytes: target.byteLength,
            seeders: 0,
            leechers: 0,
            trackerSource: .native(site: "Local"),
            infoHash: hash
        )
    }
}
