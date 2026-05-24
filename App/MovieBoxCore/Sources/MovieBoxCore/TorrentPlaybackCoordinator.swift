import CorePlayer
import CoreStorage
import CoreStreaming
import CoreTorrent
import Foundation

@MainActor
public final class TorrentPlaybackCoordinator {
    private let orchestrator: StreamingOrchestrator
    private let remuxService: RemuxService
    private(set) var session: TorrentStreamSession?
    public private(set) var torrents: [TorrentResult] = []
    public var downloadPersistence: DownloadPersistenceService?

    public init(orchestrator: StreamingOrchestrator, remuxService: RemuxService = RemuxService()) {
        self.orchestrator = orchestrator
        self.remuxService = remuxService
    }

    public func cancel() async {
        await session?.cancel()
        session = nil
        await remuxService.stopAll()
    }

    func configureSources(on playerState: PlayerState, torrents: [TorrentResult], selected: TorrentResult) {
        self.torrents = torrents
        playerState.updatePlaybackSources(Self.sourceOptions(from: torrents), selectedID: selected.id.uuidString)
        playerState.onSelectPlaybackSource = { [weak self] option in
            await self?.switchToSource(
                id: option.id,
                playerState: playerState,
                subtitleAppearance: playerState.subtitleAppearance
            )
        }
    }

    /// Creates a session and runs `start` to completion (metadata + HTTP URL). Must be awaited before `waitForPlayback` so startup is not starved by the waiter loop on the same main actor.
    public func startSession(for torrent: TorrentResult) async -> TorrentStreamSession {
        let streamSession = TorrentStreamSession(orchestrator: orchestrator)
        session = streamSession
        PlaybackLog.log("startSession — \(torrent.title)")
        await streamSession.start(torrent: torrent)
        PlaybackLog.log("startSession finished — \(streamSession.stateLabel)")
        return streamSession
    }

    /// Loads the player once `session` reaches `.ready`.
    public func finishPlayback(
        torrent: TorrentResult,
        allTorrents: [TorrentResult],
        session: TorrentStreamSession,
        playerState: PlayerState,
        movieId: Int,
        subtitleURL: URL?,
        subtitleAppearance: SubtitleAppearance = .cinematic,
        subtitleFontSize: CGFloat = 20,
        episodeTitle: String? = nil,
        displayTitle: String? = nil,
        resumePosition: Double? = nil,
        knownDurationSeconds: Double? = nil,
        posterURL: URL? = nil
    ) async throws {
        configureSources(on: playerState, torrents: allTorrents, selected: torrent)
        installStreamBufferProvider(on: playerState)

        guard case .ready(let url) = session.state else {
            if case .failed(let message) = session.state {
                PlaybackLog.log("finishPlayback aborted — stream failed: \(message)")
                throw TorrentPlaybackError.streamingFailed(message)
            }
            PlaybackLog.log("finishPlayback aborted — stream not ready (state=\(session.state))")
            throw TorrentPlaybackError.streamingFailed("Stream did not become ready.")
        }

        var playbackURL = url
        var resolvedDuration = knownDurationSeconds
        if url.isFileURL, url.pathExtension.lowercased() == "mkv" {
            let cacheKey = localHLSCacheKey(for: torrent, localURL: url)
            PlaybackLog.log("[MKVHLS] finishPlayback local mkv export detected; remux start cacheKey=\(cacheKey) file=\(MovieBoxFileLogger.redactURL(url))")
            playerState.updateBufferingDetail("Preparing AVPlayer-compatible stream…")
            let result = try await remuxService.remuxMKVToHLS(inputURL: url, cacheKey: cacheKey)
            playbackURL = result.playlistURL
            PlaybackLog.log("[MKVHLS] finishPlayback remux returned playlist=\(MovieBoxFileLogger.redactURL(playbackURL)) state=\(result.state)")
        } else if await session.isCurrentStreamMKV() {
            let cacheKey = localHLSCacheKey(for: torrent, localURL: url)
            PlaybackLog.log("[MKVHLS] finishPlayback live mkv stream detected; progressive remux start cacheKey=\(cacheKey) url=\(MovieBoxFileLogger.redactURL(url))")
            playerState.updateBufferingDetail("Preparing AVPlayer-compatible stream…")
            let result = try await remuxService.remuxStreamingMKVToHLS(inputURL: url, cacheKey: cacheKey)
            playbackURL = result.playlistURL
            PlaybackLog.log("[MKVHLS] finishPlayback live remux playable playlist=\(MovieBoxFileLogger.redactURL(playbackURL)) state=\(result.state)")
            if let duration = result.durationSeconds, duration.isFinite, duration > 0 {
                resolvedDuration = duration
            }
        }

        PlaybackLog.log("finishPlayback → loading player url=\(MovieBoxFileLogger.redactURL(playbackURL)) movieId=\(movieId) hdr=\(torrent.hdrType?.rawValue ?? "none") duration=\(resolvedDuration ?? 0)")
        let hudTitle = displayTitle.map { PlaybackDisplayTitle.clean($0) }
        // Loopback HTTP is opened by AVFoundation directly; resource loader only for custom schemes.
        let resourceLoader = TorrentPlaybackURLScheme.isTorrentPlayback(playbackURL)
            ? TorrentStreamPlaybackRegistry.shared.resourceLoader(for: playbackURL)
            : nil
        if TorrentPlaybackURLScheme.isTorrentPlayback(playbackURL), resourceLoader == nil {
            PlaybackLog.log("finishPlayback — no resource loader in registry for \(MovieBoxFileLogger.redactURL(playbackURL))")
            AgentDebugLog.write(
                hypothesisId: "H1",
                location: "TorrentPlaybackCoordinator.swift:finishPlayback",
                message: "registry lookup returned nil",
                data: ["urlHost": playbackURL.host ?? ""]
            )
        }
        let loadPayload = (
            url: playbackURL,
            title: torrent.title,
            movieId: movieId,
            subtitleURL: subtitleURL,
            hdr: playerHDRType(from: torrent.hdrType),
            audio: playerAudioFormat(from: torrent.audioFormat),
            appearance: subtitleAppearance,
            fontSize: subtitleFontSize,
            episodeTitle: episodeTitle,
            hudTitle: hudTitle,
            resume: resumePosition,
            knownDuration: resolvedDuration,
            posterURL: posterURL,
            resourceLoader: resourceLoader
        )
        Task { @MainActor in
            await Task.yield()
            playerState.updateBufferingDetail(nil)
            playerState.load(
                url: loadPayload.url,
                title: loadPayload.title,
                movieId: loadPayload.movieId,
                subtitleURL: loadPayload.subtitleURL,
                hdrType: loadPayload.hdr,
                audioFormat: loadPayload.audio,
                subtitleAppearance: loadPayload.appearance,
                subtitleFontSize: loadPayload.fontSize,
                episodeTitle: loadPayload.episodeTitle,
                displayTitle: loadPayload.hudTitle,
                resumePosition: loadPayload.resume,
                knownDurationSeconds: loadPayload.knownDuration,
                posterURL: loadPayload.posterURL,
                resourceLoaderDelegate: loadPayload.resourceLoader,
                resourceLoaderQueue: DispatchQueue(label: "com.marban.moviebox.torrent-resource-loader")
            )
        }
    }

    public func playLocalFile(
        localFilePath: String,
        torrent: TorrentResult,
        allTorrents: [TorrentResult],
        playerState: PlayerState,
        movieId: Int,
        subtitleURL: URL?,
        subtitleAppearance: SubtitleAppearance = .cinematic,
        subtitleFontSize: CGFloat = 20,
        episodeTitle: String? = nil,
        displayTitle: String? = nil,
        resumePosition: Double? = nil,
        knownDurationSeconds: Double? = nil,
        posterURL: URL? = nil
    ) {
        configureSources(on: playerState, torrents: allTorrents, selected: torrent)

        let localURL = URL(fileURLWithPath: localFilePath)
        PlaybackLog.log("playLocalFile → loading player localURL=\(MovieBoxFileLogger.redactURL(localURL)) ext=\(localURL.pathExtension.lowercased()) movieId=\(movieId) hdr=\(torrent.hdrType?.rawValue ?? "none")")
        PlaybackLog.log("[MKVHLS] playLocalFile enter title=\"\(torrent.title)\" ext=\(localURL.pathExtension.lowercased()) exists=\(FileManager.default.fileExists(atPath: localURL.path)) sourceID=\(torrent.id.uuidString)")
        let hudTitle = displayTitle.map { PlaybackDisplayTitle.clean($0) }
        let loadPayload = makeLocalPlaybackPayload(
            url: localURL,
            torrent: torrent,
            movieId: movieId,
            subtitleURL: subtitleURL,
            subtitleAppearance: subtitleAppearance,
            subtitleFontSize: subtitleFontSize,
            episodeTitle: episodeTitle,
            displayTitle: hudTitle,
            resumePosition: resumePosition,
            knownDurationSeconds: knownDurationSeconds,
            posterURL: posterURL
        )
        Task { @MainActor in
            await Task.yield()
            do {
                var resolvedPayload = loadPayload
                if localURL.pathExtension.lowercased() == "mkv" {
                    let cacheKey = localHLSCacheKey(for: torrent, localURL: localURL)
                    PlaybackLog.log("[MKVHLS] local mkv detected cacheKey=\(cacheKey) file=\(MovieBoxFileLogger.redactURL(localURL))")
                    playerState.updateBufferingDetail("Preparing AVPlayer-compatible stream…")
                    let result = try await remuxService.remuxMKVToHLS(
                        inputURL: localURL,
                        cacheKey: cacheKey
                    )
                    PlaybackLog.log("[MKVHLS] remux returned playlist=\(MovieBoxFileLogger.redactURL(result.playlistURL)) state=\(result.state)")
                    resolvedPayload.url = result.playlistURL
                } else {
                    PlaybackLog.log("[MKVHLS] non-mkv local file bypass ext=\(localURL.pathExtension.lowercased())")
                }
                PlaybackLog.log("[MKVHLS] loading player url=\(MovieBoxFileLogger.redactURL(resolvedPayload.url)) ext=\(resolvedPayload.url.pathExtension.lowercased())")
                playerState.updateBufferingDetail(nil)
                loadPlayer(playerState, payload: resolvedPayload)
            } catch {
                playerState.errorMessage = error.localizedDescription
                playerState.isBuffering = false
                playerState.bufferingDetail = nil
                PlaybackLog.log("[MKVHLS] playLocalFile remux failed: \(error.localizedDescription)")
            }
        }
    }

    func switchToSource(id: String, playerState: PlayerState, subtitleAppearance: SubtitleAppearance = .cinematic) async {
        guard let torrent = torrents.first(where: { $0.id.uuidString == id }) else { return }
        guard torrent.id.uuidString != playerState.selectedPlaybackSourceID else { return }

        let savedTime = playerState.currentTime
        let movieId = playerState.movieId
        let subtitleURL = playerState.subtitleURL

        playerState.isSwitchingSource = true
        await cancel()

        if let infoHash = torrent.resolvedInfoHash,
           let localPath = downloadPersistence?.completedFilePath(for: infoHash) {
            let localURL = URL(fileURLWithPath: localPath)
            PlaybackLog.log("[MKVHLS] switchToSource local completed file ext=\(localURL.pathExtension.lowercased()) exists=\(FileManager.default.fileExists(atPath: localURL.path)) id=\(id)")
            do {
                var playbackURL = localURL
                if localURL.pathExtension.lowercased() == "mkv" {
                    let cacheKey = localHLSCacheKey(for: torrent, localURL: localURL)
                    PlaybackLog.log("[MKVHLS] switchToSource mkv remux start cacheKey=\(cacheKey)")
                    playerState.updateBufferingDetail("Preparing AVPlayer-compatible stream…")
                    let result = try await remuxService.remuxMKVToHLS(
                        inputURL: localURL,
                        cacheKey: cacheKey
                    )
                    playbackURL = result.playlistURL
                    PlaybackLog.log("[MKVHLS] switchToSource remux returned playlist=\(MovieBoxFileLogger.redactURL(playbackURL)) state=\(result.state)")
                } else {
                    PlaybackLog.log("[MKVHLS] switchToSource non-mkv local bypass")
                }
                playerState.selectedPlaybackSourceID = id
                PlaybackLog.log("[MKVHLS] switchToSource loading player url=\(MovieBoxFileLogger.redactURL(playbackURL)) ext=\(playbackURL.pathExtension.lowercased())")
                playerState.updateBufferingDetail(nil)
                playerState.load(
                    url: playbackURL,
                    title: torrent.title,
                    movieId: movieId,
                    subtitleURL: subtitleURL,
                    hdrType: playerHDRType(from: torrent.hdrType),
                    audioFormat: playerAudioFormat(from: torrent.audioFormat),
                    subtitleAppearance: subtitleAppearance,
                    subtitleFontSize: playerState.subtitleFontSize,
                    displayTitle: playerState.seriesName,
                    resumePosition: savedTime > 20 ? savedTime : nil
                )
            } catch {
                playerState.errorMessage = error.localizedDescription
                PlaybackLog.log("[MKVHLS] switchToSource local remux failed: \(error.localizedDescription)")
            }
            playerState.isSwitchingSource = false
            return
        }

        PlaybackLog.log("[MKVHLS] switchToSource no completed local file id=\(id); falling back to streaming")

        let streamSession = TorrentStreamSession(orchestrator: orchestrator)
        session = streamSession
        await streamSession.start(torrent: torrent)

        if case .ready(let url) = streamSession.state {
            playerState.selectedPlaybackSourceID = id
            playerState.load(
                url: url,
                title: torrent.title,
                movieId: movieId,
                subtitleURL: subtitleURL,
                hdrType: playerHDRType(from: torrent.hdrType),
                audioFormat: playerAudioFormat(from: torrent.audioFormat),
                subtitleAppearance: subtitleAppearance,
                subtitleFontSize: playerState.subtitleFontSize,
                displayTitle: playerState.seriesName,
                resumePosition: savedTime > 20 ? savedTime : nil
            )
        } else if case .failed(let message) = streamSession.state {
            playerState.errorMessage = "Could not switch source: \(message)"
        }

        playerState.isSwitchingSource = false
    }

    private func playerHDRType(from type: CoreTorrent.HDRType?) -> PlayerHDRType? {
        guard let type else { return nil }
        switch type {
        case .hdr: return .hdr
        case .hdr10: return .hdr10
        case .hdr10Plus: return .hdr10Plus
        case .dolbyVisionOnly: return .dolbyVision
        case .dolbyVisionWithHDR10: return .dolbyVisionWithHDR10
        case .hlg: return .hdr
        }
    }

    private func playerAudioFormat(from format: CoreTorrent.AudioFormat?) -> PlayerAudioFormat? {
        guard format == .dolbyAtmos else { return nil }
        return .dolbyAtmos
    }

    private static func sourceOptions(from torrents: [TorrentResult]) -> [PlaybackSourceOption] {
        TorrentCatalog.sections(from: torrents).flatMap { section in
            section.variants.map { torrent in
                var details: [String] = [
                    torrent.codec.rawValue,
                    torrent.source.rawValue,
                    formatBytes(torrent.sizeBytes)
                ]
                if let hdr = torrent.hdrType {
                    details.insert(hdr.rawValue, at: 0)
                }
                if let audio = torrent.audioFormat {
                    details.append(audio.rawValue)
                }

                return PlaybackSourceOption(
                    id: torrent.id.uuidString,
                    title: torrent.title,
                    groupLabel: section.title,
                    qualityLabel: torrent.quality.rawValue,
                    languageLabel: torrent.language,
                    detailLine: "\(torrent.seeders) seeders · \(details.joined(separator: " · "))",
                    seeders: torrent.seeders
                )
            }
        }
    }

    private func installStreamBufferProvider(on playerState: PlayerState) {
        let orchestrator = orchestrator
        playerState.streamBufferTimeRangesProvider = {
            let duration = await MainActor.run { playerState.duration }
            guard duration.isFinite, duration > 0 else { return [] }
            return await orchestrator.readableMediaTimeRanges(durationSeconds: duration)
        }
    }

    private typealias LocalPlaybackPayload = (
        url: URL,
        title: String,
        movieId: Int,
        subtitleURL: URL?,
        hdr: PlayerHDRType?,
        audio: PlayerAudioFormat?,
        appearance: SubtitleAppearance,
        fontSize: CGFloat,
        episodeTitle: String?,
        hudTitle: String?,
        resume: Double?,
        knownDuration: Double?,
        posterURL: URL?
    )

    private func makeLocalPlaybackPayload(
        url: URL,
        torrent: TorrentResult,
        movieId: Int,
        subtitleURL: URL?,
        subtitleAppearance: SubtitleAppearance,
        subtitleFontSize: CGFloat,
        episodeTitle: String?,
        displayTitle: String?,
        resumePosition: Double?,
        knownDurationSeconds: Double?,
        posterURL: URL?
    ) -> LocalPlaybackPayload {
        (
            url: url,
            title: torrent.title,
            movieId: movieId,
            subtitleURL: subtitleURL,
            hdr: playerHDRType(from: torrent.hdrType),
            audio: playerAudioFormat(from: torrent.audioFormat),
            appearance: subtitleAppearance,
            fontSize: subtitleFontSize,
            episodeTitle: episodeTitle,
            hudTitle: displayTitle,
            resume: resumePosition,
            knownDuration: knownDurationSeconds,
            posterURL: posterURL
        )
    }

    private func loadPlayer(_ playerState: PlayerState, payload: LocalPlaybackPayload) {
        playerState.load(
            url: payload.url,
            title: payload.title,
            movieId: payload.movieId,
            subtitleURL: payload.subtitleURL,
            hdrType: payload.hdr,
            audioFormat: payload.audio,
            subtitleAppearance: payload.appearance,
            subtitleFontSize: payload.fontSize,
            episodeTitle: payload.episodeTitle,
            displayTitle: payload.hudTitle,
            resumePosition: payload.resume,
            knownDurationSeconds: payload.knownDuration,
            posterURL: payload.posterURL
        )
    }

    private func localHLSCacheKey(for torrent: TorrentResult, localURL: URL) -> String {
        let key = torrent.resolvedInfoHash ?? "\(torrent.id.uuidString)-\(localURL.lastPathComponent)"
        return key.lowercased()
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "Unknown size" }
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

public enum TorrentPlaybackError: LocalizedError {
    case streamingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .streamingFailed(let message): message
        }
    }
}
