import CoreMetadata
import CorePlayer
import CoreStreaming
import CoreStorage
import Foundation

public struct SubtitleSearchContext: Sendable {
    public let title: String
    public let year: Int?
    public let imdbId: String?
    public let tmdbId: Int?
    public let seasonNumber: Int?
    public let episodeNumber: Int?
    public let mediaKind: MediaKind
    public let preferredLanguage: String
    public let metadataMode: MetadataEndpointMode

    public init(
        title: String,
        year: Int?,
        imdbId: String?,
        tmdbId: Int? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        mediaKind: MediaKind,
        preferredLanguage: String,
        metadataMode: MetadataEndpointMode
    ) {
        self.title = title
        self.year = year
        self.imdbId = imdbId
        self.tmdbId = tmdbId
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.mediaKind = mediaKind
        self.preferredLanguage = preferredLanguage
        self.metadataMode = metadataMode
    }
}

@MainActor
public enum SubtitlePlaybackSupport {
    /// Wires catalog search, embedded extraction, and in-player subtitle switching after playback starts.
    public static func attachToPlayback(
        playerState: PlayerState,
        catalog: [SubtitleInfo],
        searchContext: SubtitleSearchContext?,
        selectedSubtitleID: String? = nil,
        localMediaPath: String? = nil,
        session: TorrentStreamSession? = nil,
        autoSelectRemote: Bool = false
    ) {
        configure(
            playerState: playerState,
            catalog: catalog,
            searchContext: searchContext,
            selectedSubtitleID: selectedSubtitleID,
            autoSelectRemote: autoSelectRemote
        )

        let preferredLanguage = searchContext?.preferredLanguage ?? "en"
        playerState.onEmbeddedLegibleTracksDiscovered = { tracks in
            mergeEmbeddedLegibleTracks(
                playerState: playerState,
                tracks: tracks,
                preferredLanguage: preferredLanguage
            )
        }

        if let session {
            playerState.resolveEmbeddedMediaURL = {
                await session.mediaFileURLForSubtitleProbe()
            }
        } else if let localMediaPath {
            let fileURL = URL(fileURLWithPath: localMediaPath)
            playerState.resolveEmbeddedMediaURL = { fileURL }
        }

        Task {
            if let localMediaPath {
                await attachEmbeddedSubtitles(
                    playerState: playerState,
                    mediaFileURL: URL(fileURLWithPath: localMediaPath),
                    preferredLanguage: preferredLanguage,
                    isCompleteFile: true
                )
            } else if let session {
                await attachEmbeddedFromSession(
                    playerState: playerState,
                    session: session,
                    preferredLanguage: preferredLanguage
                )
            }
            if let context = searchContext {
                _ = await ensurePreferredSubtitleSelected(
                    playerState: playerState,
                    mode: context.metadataMode
                )
            }
        }
    }

    /// Applies a user-downloaded `.srt` to the active player when it matches the current title.
    public static func applyDownloadedFile(
        _ fileURL: URL,
        subtitleID: String,
        to playerState: PlayerState,
        movieId: Int
    ) {
        guard playerState.isPresented, playerState.movieId == movieId else { return }
        playerState.selectedSubtitleID = subtitleID
        playerState.loadSubtitleStream(from: fileURL)
        playerState.setSubtitlesEnabled(true)
    }

    public static func configure(
        playerState: PlayerState,
        catalog: [SubtitleInfo],
        searchContext: SubtitleSearchContext?,
        selectedSubtitleID: String? = nil,
        autoSelectRemote: Bool = true
    ) {
        playerState.availableSubtitles = catalog.map(PlayerSubtitleOption.init(info:))
        playerState.selectedSubtitleID = selectedSubtitleID
            ?? preferredOption(from: playerState.availableSubtitles)?.id
            ?? catalog.first.map(\.id)
        playerState.isLoadingSubtitleCatalog = false

        playerState.onSelectSubtitle = { option in
            await selectSubtitle(
                option,
                playerState: playerState,
                mode: searchContext?.metadataMode
            )
        }

        if let searchContext {
            playerState.onRefreshSubtitles = {
                await refreshCatalog(playerState: playerState, context: searchContext)
            }
            playerState.onEnsureSubtitleSelected = {
                await ensurePreferredSubtitleSelected(
                    playerState: playerState,
                    mode: searchContext.metadataMode
                )
            }

            if autoSelectRemote, playerState.subtitleURL == nil, !catalog.isEmpty {
                Task {
                    await ensurePreferredSubtitleSelected(
                        playerState: playerState,
                        mode: searchContext.metadataMode
                    )
                }
            }
        } else {
            playerState.onRefreshSubtitles = nil
            playerState.onEnsureSubtitleSelected = nil
        }
    }

    public static func mergeEmbeddedLegibleTracks(
        playerState: PlayerState,
        tracks: [EmbeddedLegibleTrack],
        preferredLanguage: String
    ) {
        guard !tracks.isEmpty else { return }

        let avOptions = tracks.map { track in
            PlayerSubtitleOption(
                id: "embedded-av:\(track.index)",
                name: track.displayName,
                author: "In video",
                language: track.language,
                downloadPath: "",
                embeddedStreamIndex: track.index,
                usesAVPlayerLegible: true
            )
        }

        let ffmpegEmbedded = playerState.availableSubtitles.filter {
            $0.isEmbedded && !$0.usesAVPlayerLegible
        }
        let remote = playerState.availableSubtitles.filter { !$0.isEmbedded }
        let embeddedOptions =
            EmbeddedSubtitleExtractor.isAvailable
            ? avOptions + ffmpegEmbedded
            : avOptions
        playerState.availableSubtitles = embeddedOptions + remote

        if playerState.selectedSubtitleID == nil
            || !playerState.availableSubtitles.contains(where: { $0.id == playerState.selectedSubtitleID }) {
            playerState.selectedSubtitleID = preferredOption(
                from: playerState.availableSubtitles,
                preferredLanguage: preferredLanguage
            )?.id
        }

        if playerState.subtitleURL == nil, playerState.activeSubtitleTrack < 0 {
            Task {
                _ = await ensurePreferredSubtitleSelected(playerState: playerState, mode: nil)
            }
        }
    }

    /// Probes a local file (or torrent export) via ffmpeg when available.
    public static func attachEmbeddedSubtitles(
        playerState: PlayerState,
        mediaFileURL: URL,
        preferredLanguage: String,
        isCompleteFile: Bool = false
    ) async {
        let tracks = await EmbeddedSubtitleExtractor.probe(
            mediaFileURL: mediaFileURL,
            isCompleteFile: isCompleteFile
        )
        guard !tracks.isEmpty else { return }

        let embeddedOptions = tracks.map { track in
            PlayerSubtitleOption(
                id: "embedded-ff:\(track.index)",
                name: track.displayName,
                author: "In video",
                language: track.language,
                downloadPath: "",
                embeddedStreamIndex: track.index,
                sourceMediaPath: mediaFileURL.path
            )
        }

        let avEmbedded = playerState.availableSubtitles.filter(\.usesAVPlayerLegible)
        let remote = playerState.availableSubtitles.filter { !$0.isEmbedded }
        playerState.availableSubtitles = avEmbedded + embeddedOptions + remote

        if playerState.selectedSubtitleID == nil || !playerState.availableSubtitles.contains(where: { $0.id == playerState.selectedSubtitleID }) {
            playerState.selectedSubtitleID = preferredOption(
                from: playerState.availableSubtitles,
                preferredLanguage: preferredLanguage
            )?.id
        }

        if playerState.subtitleURL == nil {
            _ = await ensurePreferredSubtitleSelected(playerState: playerState, mode: nil)
        }
    }

    public static func attachEmbeddedFromSession(
        playerState: PlayerState,
        session: TorrentStreamSession,
        preferredLanguage: String
    ) async {
        guard let mediaURL = await session.mediaFileURLForSubtitleProbe() else { return }
        await attachEmbeddedSubtitles(
            playerState: playerState,
            mediaFileURL: mediaURL,
            preferredLanguage: preferredLanguage
        )
    }

    public static func preferredEnglishOption(from options: [PlayerSubtitleOption]) -> PlayerSubtitleOption? {
        preferredOption(from: options, preferredLanguage: "en")
    }

    public static func preferredOption(
        from options: [PlayerSubtitleOption],
        preferredLanguage: String = "en"
    ) -> PlayerSubtitleOption? {
        let embedded = options.filter(\.isEmbedded)
        let avEmbedded = embedded.filter(\.usesAVPlayerLegible)
        let embeddedPool = avEmbedded.isEmpty ? embedded : avEmbedded
        if let embeddedPick = pickLanguageMatch(from: embeddedPool, preferredLanguage: preferredLanguage)
            ?? embeddedPool.first {
            return embeddedPick
        }
        return pickLanguageMatch(from: options, preferredLanguage: preferredLanguage) ?? options.first
    }

    private static func pickLanguageMatch(
        from options: [PlayerSubtitleOption],
        preferredLanguage: String
    ) -> PlayerSubtitleOption? {
        let needle = preferredLanguage.lowercased()
        return options.first { option in
            let lang = option.language.lowercased()
            return lang == needle || lang == "english" && needle == "en" || lang.hasPrefix(needle) || needle.hasPrefix(lang)
        }
    }

    public static func refreshCatalog(
        playerState: PlayerState,
        context: SubtitleSearchContext
    ) async {
        playerState.isLoadingSubtitleCatalog = true
        playerState.setSubtitleLoadProgress(
            SubtitleLoadProgress(title: "Searching subtitles", detail: context.title)
        )
        defer {
            playerState.isLoadingSubtitleCatalog = false
            if playerState.subtitleLoadProgress?.title == "Searching subtitles" {
                playerState.setSubtitleLoadProgress(nil)
            }
        }

        let embedded = playerState.availableSubtitles.filter(\.isEmbedded)
        let client = SubtitleClient(mode: context.metadataMode)
        do {
            let subtitles = try await client.searchSubtitles(
                title: context.title,
                year: context.year,
                language: "all",
                type: context.mediaKind == .tv ? "tv" : "movie",
                imdbId: context.imdbId,
                tmdbId: context.tmdbId,
                seasonNumber: context.seasonNumber,
                episodeNumber: context.episodeNumber
            )
            playerState.availableSubtitles = embedded + subtitles.map(PlayerSubtitleOption.init(info:))
            if playerState.selectedSubtitleID == nil {
                playerState.selectedSubtitleID = preferredOption(
                    from: playerState.availableSubtitles,
                    preferredLanguage: context.preferredLanguage
                )?.id
            }
        } catch {
            NSLog("Subtitle catalog refresh failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    public static func ensurePreferredSubtitleSelected(
        playerState: PlayerState,
        mode: MetadataEndpointMode?
    ) async -> Bool {
        if playerState.subtitleURL != nil, playerState.activeSubtitleTrack >= 0 {
            return true
        }

        let option: PlayerSubtitleOption?
        if let selectedID = playerState.selectedSubtitleID,
           let match = playerState.availableSubtitles.first(where: { $0.id == selectedID }) {
            option = match
        } else {
            option = preferredOption(from: playerState.availableSubtitles)
        }

        guard let option else { return false }
        await selectSubtitle(option, playerState: playerState, mode: mode)
        return playerState.subtitleURL != nil
    }

    public static func selectSubtitle(
        _ option: PlayerSubtitleOption,
        playerState: PlayerState,
        mode: MetadataEndpointMode?
    ) async {
        playerState.selectedSubtitleID = option.id
        let detail = option.name

        if option.usesAVPlayerLegible, let streamIndex = option.embeddedStreamIndex {
            playerState.selectEmbeddedLegibleTrack(at: streamIndex)
            playerState.setSubtitlesEnabled(true)
            return
        }

        if let streamIndex = option.embeddedStreamIndex {
            let outputURL = subtitleFileURL(for: option.id)
            playerState.setSubtitleLoadProgress(
                SubtitleLoadProgress(title: "Extracting from video", detail: detail)
            )

            var mediaURL: URL?
            if let mediaPath = option.sourceMediaPath {
                mediaURL = URL(fileURLWithPath: mediaPath)
            }
            if let resolve = playerState.resolveEmbeddedMediaURL, let fresh = await resolve() {
                mediaURL = fresh
            }

            guard let mediaURL else {
                playerState.setSubtitleLoadProgress(
                    SubtitleLoadProgress(
                        title: "Extraction failed",
                        detail: "Video file not available yet — buffer more and try again."
                    )
                )
                try? await Task.sleep(for: .seconds(3))
                playerState.setSubtitleLoadProgress(nil)
                return
            }

            do {
                try await EmbeddedSubtitleExtractor.extract(
                    mediaFileURL: mediaURL,
                    streamIndex: streamIndex,
                    outputURL: outputURL
                )
                playerState.loadSubtitleStream(from: outputURL)
                playerState.setSubtitlesEnabled(true)
            } catch {
                await handleEmbeddedExtractFailure(
                    error: error,
                    playerState: playerState,
                    streamIndex: streamIndex,
                    option: option
                )
            }
            return
        }

        guard let mode else { return }
        playerState.setSubtitleLoadProgress(
            SubtitleLoadProgress(title: "Downloading subtitle", detail: detail)
        )
        let client = SubtitleClient(mode: mode)
        do {
            let data = try await client.downloadSubtitle(url: option.downloadPath)
            guard SubtitlePayloadValidator.looksLikeSRT(data) else {
                NSLog("Subtitle download rejected — not valid SRT (\(option.name))")
                playerState.setSubtitleLoadProgress(
                    SubtitleLoadProgress(title: "Invalid subtitle file", detail: detail)
                )
                try? await Task.sleep(for: .seconds(2.5))
                playerState.setSubtitleLoadProgress(nil)
                return
            }
            let fileURL = subtitleFileURL(for: option.id)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL)
            playerState.loadSubtitleStream(from: fileURL)
            playerState.setSubtitlesEnabled(true)
        } catch {
            NSLog("Subtitle download failed: \(error.localizedDescription)")
            playerState.setSubtitleLoadProgress(
                SubtitleLoadProgress(
                    title: "Download failed",
                    detail: error.localizedDescription
                )
            )
            try? await Task.sleep(for: .seconds(3))
            playerState.setSubtitleLoadProgress(nil)
        }
    }

    private static func handleEmbeddedExtractFailure(
        error: Error,
        playerState: PlayerState,
        streamIndex: Int,
        option: PlayerSubtitleOption
    ) async {
        NSLog("Embedded subtitle extract failed: \(error.localizedDescription)")
        let avTracks = await playerState.discoverEmbeddedLegibleTracks()
        if let fallback = avTracks.first(where: { $0.index == streamIndex })
            ?? avTracks.first(where: { $0.language.lowercased() == option.language.lowercased() })
            ?? avTracks.first {
            playerState.selectEmbeddedLegibleTrack(at: fallback.index)
            playerState.setSubtitlesEnabled(true)
            playerState.setSubtitleLoadProgress(nil)
            return
        }
        playerState.setSubtitleLoadProgress(
            SubtitleLoadProgress(
                title: "Extraction failed",
                detail: error.localizedDescription
            )
        )
        try? await Task.sleep(for: .seconds(3))
        playerState.setSubtitleLoadProgress(nil)
    }

    private static func subtitleFileURL(for optionID: String) -> URL {
        let safeName = optionID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let fileName = safeName.isEmpty ? UUID().uuidString : safeName
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("moviebox_subtitles", isDirectory: true)
            .appendingPathComponent("\(fileName).srt")
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
