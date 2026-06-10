import CoreMetadata
import CoreStorage
import Foundation
import SwiftData

public enum SubtitlePreferenceStore {
    public struct Scope: Sendable, Equatable {
        public let season: Int
        public let episode: Int

        public init(season: Int = 0, episode: Int = 0) {
            self.season = max(0, season)
            self.episode = max(0, episode)
        }

        public static func movie() -> Scope { Scope() }

        public static func tv(season: Int, episode: Int) -> Scope {
            Scope(season: season, episode: episode)
        }
    }

    public static func scope(
        mediaKind: MediaKind,
        season: Int?,
        episode: Int?
    ) -> Scope {
        guard mediaKind == .tv,
              let season, season > 0,
              let episode, episode > 0
        else { return .movie() }
        return .tv(season: season, episode: episode)
    }

    public static func matches(_ record: MovieRecord, scope: Scope) -> Bool {
        record.lastSubtitleSeason == scope.season && record.lastSubtitleEpisode == scope.episode
    }

    public static func savedPreference(
        record: MovieRecord,
        scope: Scope
    ) -> (id: String, path: String?)? {
        guard matches(record, scope: scope) else { return nil }
        let id = record.lastSelectedSubtitleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        let path = record.lastSelectedSubtitlePath
        if let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            return (id, path)
        }
        return (id, nil)
    }

    @MainActor
    public static func savePreference(
        tmdbId: Int,
        subtitleID: String,
        filePath: String?,
        scope: Scope,
        in context: ModelContext,
        records: [MovieRecord]
    ) {
        guard tmdbId > 0 else { return }
        let cleanedID = subtitleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedID.isEmpty else { return }

        let record = records.first(where: { $0.tmdbId == tmdbId })
            ?? {
                let created = MovieRecord(tmdbId: tmdbId, title: "")
                context.insert(created)
                return created
            }()

        record.lastSelectedSubtitleID = cleanedID
        record.lastSelectedSubtitlePath = filePath
        record.lastSubtitleSeason = scope.season
        record.lastSubtitleEpisode = scope.episode
        try? context.save()
    }

    public static func standardSubtitleURL(
        in directory: URL,
        subtitleID: String? = nil
    ) -> URL {
        let base = directory.appendingPathComponent("MovieBox.subtitle", isDirectory: false)
        guard let subtitleID,
              !subtitleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return base.appendingPathExtension("srt")
        }
        let safe = subtitleID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent("MovieBox.subtitle.\(safe).srt")
    }

    public static func resolvePlaybackSubtitleURL(
        nearMediaFile mediaPath: String,
        movieRecord: MovieRecord?,
        downloadRecord: DownloadRecord?,
        scope: Scope
    ) -> URL? {
        if let downloadRecord,
           let path = downloadRecord.localSubtitlePath,
           !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        if let movieRecord,
           let saved = savedPreference(record: movieRecord, scope: scope),
           let path = saved.path {
            return URL(fileURLWithPath: path)
        }

        let mediaURL = URL(fileURLWithPath: mediaPath)
        let directory = mediaURL.deletingLastPathComponent()
        let candidates: [URL] = [
            standardSubtitleURL(in: directory),
            standardSubtitleURL(in: directory, subtitleID: movieRecord?.lastSelectedSubtitleID),
            standardSubtitleURL(in: directory, subtitleID: downloadRecord?.selectedSubtitleID),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @discardableResult
    public static func downloadSubtitle(
        _ subtitle: SubtitleInfo,
        mode: MetadataEndpointMode,
        to outputURL: URL
    ) async throws -> URL {
        let client = SubtitleClient(mode: mode)
        let data = try await client.downloadSubtitle(url: subtitle.downloadUrl)
        guard SubtitlePayloadValidator.looksLikeSRT(data) else {
            throw SubtitleError.invalidPayload
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
        return outputURL
    }

    /// Downloads the chosen subtitle beside a completed download folder and updates persistence.
    @MainActor
    public static func attachSubtitleToDownload(
        subtitle: SubtitleInfo,
        mode: MetadataEndpointMode,
        storageDirectory: URL,
        mediaFilePath: String?,
        tmdbId: Int,
        scope: Scope,
        downloadRecord: DownloadRecord?,
        movieRecord: MovieRecord?,
        modelContext: ModelContext
    ) async -> URL? {
        let outputURL = standardSubtitleURL(in: storageDirectory, subtitleID: subtitle.id)
        do {
            _ = try await downloadSubtitle(subtitle, mode: mode, to: outputURL)
        } catch {
            NSLog("Subtitle download for saved file failed: \(error.localizedDescription)")
            return nil
        }

        if let downloadRecord {
            downloadRecord.selectedSubtitleID = subtitle.id
            downloadRecord.localSubtitlePath = outputURL.path
        }

        if let movieRecord, tmdbId > 0 {
            movieRecord.lastSelectedSubtitleID = subtitle.id
            movieRecord.lastSelectedSubtitlePath = outputURL.path
            movieRecord.lastSubtitleSeason = scope.season
            movieRecord.lastSubtitleEpisode = scope.episode
        } else if tmdbId > 0 {
            savePreference(
                tmdbId: tmdbId,
                subtitleID: subtitle.id,
                filePath: outputURL.path,
                scope: scope,
                in: modelContext,
                records: []
            )
        }

        if let mediaFilePath, !mediaFilePath.isEmpty {
            _ = mediaFilePath
        }

        try? modelContext.save()
        return outputURL
    }
}
