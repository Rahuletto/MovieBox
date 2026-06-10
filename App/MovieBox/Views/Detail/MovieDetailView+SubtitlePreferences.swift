import CoreMetadata
import CoreStorage
import MovieBoxCore
import SwiftData
import SwiftUI

extension MovieDetailView {
    var subtitlePreferenceScope: SubtitlePreferenceStore.Scope {
        SubtitlePreferenceStore.scope(
            mediaKind: kind,
            season: kind == .tv ? selectedTVEpisode?.seasonNumber : nil,
            episode: kind == .tv ? selectedTVEpisode?.episodeNumber : nil
        )
    }

    func restoreSavedSubtitleSelection() {
        guard let record = storedMovies.first(where: { $0.tmdbId == movieId }) else { return }
        guard let saved = SubtitlePreferenceStore.savedPreference(
            record: record,
            scope: subtitlePreferenceScope
        ) else { return }

        if let match = subtitles.first(where: { $0.id == saved.id }) {
            selectedSubtitle = match
        }
        if let path = saved.path {
            subtitleFileURL = URL(fileURLWithPath: path)
        }
    }

    func persistSubtitleSelection(id: String, fileURL: URL?) {
        SubtitlePreferenceStore.savePreference(
            tmdbId: movieId,
            subtitleID: id,
            filePath: fileURL?.path,
            scope: subtitlePreferenceScope,
            in: modelContext,
            records: storedMovies
        )
    }

    func makeSubtitlePersistHandler() -> @MainActor (String, URL?) -> Void {
        { [self] id, url in
            persistSubtitleSelection(id: id, fileURL: url)
        }
    }

    func resolvedSubtitleForPlayback(
        mediaPath: String?,
        infoHash: String?
    ) -> URL? {
        let downloadRecord = infoHash.flatMap { hash in
            downloads.first { $0.infoHash.lowercased() == hash.lowercased() }
        }
        let movieRecord = storedMovies.first { $0.tmdbId == movieId }
        if let mediaPath, !mediaPath.isEmpty {
            return SubtitlePreferenceStore.resolvePlaybackSubtitleURL(
                nearMediaFile: mediaPath,
                movieRecord: movieRecord,
                downloadRecord: downloadRecord,
                scope: subtitlePreferenceScope
            )
        }
        if let saved = movieRecord.flatMap({
            SubtitlePreferenceStore.savedPreference(record: $0, scope: subtitlePreferenceScope)
        }), let path = saved.path {
            return URL(fileURLWithPath: path)
        }
        return subtitleFileURL
    }

    func subtitleToDownloadWithMedia() -> SubtitleInfo? {
        if let selectedSubtitle { return selectedSubtitle }
        guard let record = storedMovies.first(where: { $0.tmdbId == movieId }),
              let saved = SubtitlePreferenceStore.savedPreference(
                  record: record,
                  scope: subtitlePreferenceScope
              ),
              let match = subtitles.first(where: { $0.id == saved.id })
        else { return subtitles.first }
        return match
    }

    func downloadSubtitleForStorageDirectory(
        _ storageDirectory: URL,
        mediaPath: String?,
        infoHash: String?
    ) async {
        guard let mode = settings.first?.subtitleServiceMode,
              let subtitle = subtitleToDownloadWithMedia()
        else { return }

        let downloadRecord = infoHash.flatMap { hash in
            downloads.first { $0.infoHash.lowercased() == hash.lowercased() }
        }
        let movieRecord = storedMovies.first { $0.tmdbId == movieId }

        if let url = await SubtitlePreferenceStore.attachSubtitleToDownload(
            subtitle: subtitle,
            mode: mode,
            storageDirectory: storageDirectory,
            mediaFilePath: mediaPath,
            tmdbId: movieId,
            scope: subtitlePreferenceScope,
            downloadRecord: downloadRecord,
            movieRecord: movieRecord,
            modelContext: modelContext
        ) {
            await MainActor.run {
                selectedSubtitle = subtitle
                subtitleFileURL = url
            }
        }
    }
}
