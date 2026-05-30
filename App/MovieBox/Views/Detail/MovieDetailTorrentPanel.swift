import CoreMetadata
import CoreStorage
import CoreStreaming
import CoreTorrent
import Foundation
import MovieBoxCore
import MovieBoxDetail

@MainActor
@Observable
final class MovieDetailTorrentPanel {
    var torrents: [TorrentResult] = []
    var searchDiagnostics: TorrentSearchDiagnostics?
    var isLoading = false

    private var searchTask: Task<Void, Never>?
    private var generation = 0

    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
    }

    func reset() {
        cancelSearch()
        torrents = []
        searchDiagnostics = nil
        isLoading = false
    }

    func restoreCached(_ entry: MovieDetailTorrentCache.Entry) {
        cancelSearch()
        torrents = entry.torrents
        searchDiagnostics = entry.diagnostics
        isLoading = false
    }

    func startSearch(
        movieId: Int,
        kind: MediaKind,
        detail: MovieDetail,
        settings: AppSettings?,
        episode: TVEpisode?,
        onDetailRefresh: @escaping @MainActor (MovieDetail) -> Void,
        onPrewarm: @escaping @MainActor ([TorrentResult]) -> Void
    ) {
        searchTask?.cancel()
        generation += 1
        let searchGeneration = generation
        searchTask = Task {
            await runSearch(
                movieId: movieId,
                kind: kind,
                detail: detail,
                settings: settings,
                episode: episode,
                generation: searchGeneration,
                onDetailRefresh: onDetailRefresh,
                onPrewarm: onPrewarm
            )
        }
    }

    private func runSearch(
        movieId: Int,
        kind: MediaKind,
        detail: MovieDetail,
        settings: AppSettings?,
        episode: TVEpisode?,
        generation: Int,
        onDetailRefresh: @escaping @MainActor (MovieDetail) -> Void,
        onPrewarm: @escaping @MainActor ([TorrentResult]) -> Void
    ) async {
        guard !Task.isCancelled else { return }

        let searchDetail = await MovieDetailLoader.freshDetailForTorrentSearch(
            movieId: movieId,
            kind: kind,
            settings: settings,
            fallback: detail
        )

        guard generation == self.generation else { return }
        onDetailRefresh(searchDetail)
        isLoading = true
        torrents = []
        searchDiagnostics = nil

        for await update in MovieDetailTorrentSearch.searchStream(
            detail: searchDetail,
            kind: kind,
            settings: settings,
            episode: episode
        ) {
            guard !Task.isCancelled else { break }
            guard generation == self.generation else { return }

            logUpdate(update, settings: settings)
            torrents = update.torrents
            if let diagnostics = update.diagnostics {
                searchDiagnostics = diagnostics
            }
            if update.isComplete {
                isLoading = false
                onPrewarm(update.torrents)
                let cacheKey = MovieDetailTorrentCache.key(movieId: movieId, kind: kind, episode: episode)
                let fingerprint = PlaybackDiskCache.indexerFingerprint(settings?.enabledTorrentIndexers)
                MovieDetailTorrentCache.store(
                    key: cacheKey,
                    indexerFingerprint: fingerprint,
                    torrents: update.torrents,
                    diagnostics: searchDiagnostics
                )
            }
        }

        if Task.isCancelled { return }
        guard generation == self.generation else { return }
        isLoading = false
    }

    func playFailureMessage(title: String, kind: MediaKind, imdbId: String?) -> String {
        MovieDetailTorrentSearch.playFailureMessage(
            diagnostics: searchDiagnostics,
            title: title,
            kind: kind,
            imdbId: imdbId
        )
    }

    private func logUpdate(_ update: MovieDetailTorrentSearch.ProgressUpdate, settings: AppSettings?) {
        let sourceCounts = Dictionary(grouping: update.torrents, by: { $0.trackerSource.label })
            .mapValues(\.count)
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        let nativeCounts = update.diagnostics?.nativeCounts
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ") ?? "nil"
        let nativeErrors = update.diagnostics?.nativeErrors
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ") ?? "nil"
        let backendURL = settings.map { BackendProxyURL.resolved(from: $0) } ?? "unknown"
        NSLog(
            "Torrent search update — backend=\(backendURL) complete=\(update.isComplete) visible=\(update.torrents.count) sources=[\(sourceCounts)] nativeCounts=[\(nativeCounts)] nativeErrors=[\(nativeErrors)]"
        )
    }
}
