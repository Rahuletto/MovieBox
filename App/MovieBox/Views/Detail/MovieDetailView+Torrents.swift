import CoreMetadata
import CoreStorage
import MovieBoxCore
import MovieBoxDetail
import SwiftUI

extension MovieDetailView {
    private var torrentIndexerFingerprint: String {
        PlaybackDiskCache.indexerFingerprint(settings.first?.enabledTorrentIndexers)
    }

    @discardableResult
    func restoreTorrentListIfCached(episode: TVEpisode? = nil) -> Bool {
        let key = MovieDetailTorrentCache.key(
            movieId: movieId,
            kind: kind,
            episode: episode ?? selectedTVEpisode
        )
        guard let cached = MovieDetailTorrentCache.entry(
            for: key,
            indexerFingerprint: torrentIndexerFingerprint
        ), !cached.torrents.isEmpty else {
            return false
        }
        torrentPanel.restoreCached(cached)
        return true
    }

    func startTorrentSearch(episode: TVEpisode? = nil) {
        guard let resolvedDetail = detail else { return }
        torrentPanel.startSearch(
            movieId: movieId,
            kind: kind,
            detail: resolvedDetail,
            settings: settings.first,
            episode: episode,
            onDetailRefresh: { self.detail = $0 },
            onPrewarm: { appServices.prewarmStreamingMetadata(for: $0) }
        )
    }
}
