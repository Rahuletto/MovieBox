import CoreMetadata
import CorePlayer
import CoreStorage
import Foundation

public struct SubtitleSearchContext: Sendable {
    public let title: String
    public let year: Int?
    public let imdbId: String?
    public let mediaKind: MediaKind
    public let preferredLanguage: String
    public let metadataMode: MetadataEndpointMode

    public init(
        title: String,
        year: Int?,
        imdbId: String?,
        mediaKind: MediaKind,
        preferredLanguage: String,
        metadataMode: MetadataEndpointMode
    ) {
        self.title = title
        self.year = year
        self.imdbId = imdbId
        self.mediaKind = mediaKind
        self.preferredLanguage = preferredLanguage
        self.metadataMode = metadataMode
    }
}

@MainActor
public enum SubtitlePlaybackSupport {
    public static func configure(
        playerState: PlayerState,
        catalog: [SubtitleInfo],
        searchContext: SubtitleSearchContext?,
        selectedSubtitleID: String? = nil
    ) {
        playerState.availableSubtitles = catalog.map(PlayerSubtitleOption.init(info:))
        playerState.selectedSubtitleID = selectedSubtitleID ?? catalog.first?.id
        playerState.isLoadingSubtitleCatalog = false

        guard let searchContext else {
            playerState.onRefreshSubtitles = nil
            playerState.onSelectSubtitle = nil
            return
        }

        playerState.onRefreshSubtitles = {
            await refreshCatalog(playerState: playerState, context: searchContext)
        }
        playerState.onSelectSubtitle = { option in
            await selectSubtitle(option, playerState: playerState, mode: searchContext.metadataMode)
        }
    }

    public static func refreshCatalog(
        playerState: PlayerState,
        context: SubtitleSearchContext
    ) async {
        playerState.isLoadingSubtitleCatalog = true
        defer { playerState.isLoadingSubtitleCatalog = false }

        let client = SubtitleClient(mode: context.metadataMode) // always .backend from search context
        do {
            let subtitles = try await client.searchSubtitles(
                title: context.title,
                year: context.year,
                language: "all",
                type: context.mediaKind == .tv ? "tv" : "movie",
                imdbId: context.imdbId
            )
            playerState.availableSubtitles = subtitles.map(PlayerSubtitleOption.init(info:))
            if playerState.selectedSubtitleID == nil {
                playerState.selectedSubtitleID = subtitles.first?.id
            }
        } catch {
            NSLog("Subtitle catalog refresh failed: \(error.localizedDescription)")
        }
    }

    public static func selectSubtitle(
        _ option: PlayerSubtitleOption,
        playerState: PlayerState,
        mode: MetadataEndpointMode
    ) async {
        playerState.selectedSubtitleID = option.id
        let client = SubtitleClient(mode: mode)
        do {
            let data = try await client.downloadSubtitle(url: option.downloadPath)
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("moviebox_subtitles", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("\(option.id).srt")
            try data.write(to: fileURL)
            playerState.loadSubtitleStream(from: fileURL)
            playerState.setSubtitlesEnabled(true)
        } catch {
            NSLog("Subtitle download failed: \(error.localizedDescription)")
        }
    }
}

private extension PlayerSubtitleOption {
    init(info: SubtitleInfo) {
        self.init(
            id: info.id,
            name: info.name,
            author: info.author,
            language: info.language,
            downloadPath: info.downloadUrl
        )
    }
}
