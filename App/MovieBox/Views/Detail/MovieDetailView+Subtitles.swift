import CoreMetadata
import CorePlayer
import CoreStreaming
import MovieBoxCore
import MovieBoxDetail
import SwiftUI

extension MovieDetailView {
    func searchSubtitles(for movie: Movie, episode: TVEpisode? = nil) {
        subtitleSearchTask?.cancel()
        subtitleSearchGeneration += 1
        let generation = subtitleSearchGeneration
        subtitleSearchTask = Task {
            await MainActor.run {
                isLoadingSubtitles = true
                subtitles = []
                subtitleFileURL = nil
                selectedSubtitle = nil
            }
            do {
                guard let mode = MovieDetailLoader.subtitleServiceMode(from: settings.first) else {
                    await MainActor.run {
                        guard generation == subtitleSearchGeneration else { return }
                        subtitleLoadHint = "Add your MovieBox backend URL and app token in Settings."
                        errorMessage = "Configure the MovieBox backend in Settings to search subtitles."
                        isLoadingSubtitles = false
                    }
                    return
                }
                let year = Int(movie.releaseDate.prefix(4))
                let client = SubtitleClient(mode: mode)
                let activeEpisode = episode ?? selectedTVEpisode
                let results = try await client.searchSubtitles(
                    title: movie.title,
                    year: year,
                    language: "all",
                    type: kind == .tv ? "tv" : "movie",
                    imdbId: detail?.imdbId,
                    tmdbId: movieId,
                    seasonNumber: kind == .tv ? activeEpisode?.seasonNumber : nil,
                    episodeNumber: kind == .tv ? activeEpisode?.episodeNumber : nil
                )
                await MainActor.run {
                    guard generation == subtitleSearchGeneration else { return }
                    subtitles = results
                    if !results.isEmpty { subtitleLoadHint = nil }
                    restoreSavedSubtitleSelection()
                }
            } catch {
                await MainActor.run {
                    guard generation == subtitleSearchGeneration else { return }
                    subtitleLoadHint = error.localizedDescription
                }
            }
            await MainActor.run {
                guard generation == subtitleSearchGeneration else { return }
                isLoadingSubtitles = false
            }
        }
    }

    func downloadSubtitle(_ subtitle: SubtitleInfo) {
        Task { await downloadSubtitleAsync(subtitle) }
    }

    func downloadSubtitleAsync(_ subtitle: SubtitleInfo) async {
        selectedSubtitle = subtitle
        do {
            guard let mode = MovieDetailLoader.subtitleServiceMode(from: settings.first) else { return }
            let client = SubtitleClient(mode: mode)
            let data = try await client.downloadSubtitle(url: subtitle.downloadUrl)
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("moviebox_subtitles")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("\(subtitle.id).srt")
            try data.write(to: fileURL)
            subtitleFileURL = fileURL
            persistSubtitleSelection(id: subtitle.id, fileURL: fileURL)
            SubtitlePlaybackSupport.applyDownloadedFile(
                fileURL,
                subtitleID: subtitle.id,
                to: playerState,
                movieId: movieId
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
