import CorePlayer
import CoreStorage
import CoreStreaming
import CoreTorrent
import Foundation

@MainActor
public final class TorrentPlaybackCoordinator {
    private let orchestrator: StreamingOrchestrator
    private(set) var session: TorrentStreamSession?
    public private(set) var torrents: [TorrentResult] = []
    public var downloadPersistence: DownloadPersistenceService?

    public init(orchestrator: StreamingOrchestrator) {
        self.orchestrator = orchestrator
    }

    public func cancel() async {
        await session?.cancel()
        session = nil
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
        knownDurationSeconds: Double? = nil
    ) throws {
        configureSources(on: playerState, torrents: allTorrents, selected: torrent)

        guard case .ready(let url) = session.state else {
            if case .failed(let message) = session.state {
                PlaybackLog.log("finishPlayback aborted — stream failed: \(message)")
                throw TorrentPlaybackError.streamingFailed(message)
            }
            PlaybackLog.log("finishPlayback aborted — stream not ready (state=\(session.state))")
            throw TorrentPlaybackError.streamingFailed("Stream did not become ready.")
        }

        PlaybackLog.log("finishPlayback → loading player url=\(MovieBoxFileLogger.redactURL(url)) movieId=\(movieId) hdr=\(torrent.hdrType?.rawValue ?? "none")")
        let hudTitle = displayTitle.map { PlaybackDisplayTitle.clean($0) }
        // Loopback HTTP is opened by AVFoundation directly; resource loader only for custom schemes.
        let resourceLoader = TorrentPlaybackURLScheme.isTorrentPlayback(url)
            ? TorrentStreamPlaybackRegistry.shared.resourceLoader(for: url)
            : nil
        if TorrentPlaybackURLScheme.isTorrentPlayback(url), resourceLoader == nil {
            PlaybackLog.log("finishPlayback — no resource loader in registry for \(MovieBoxFileLogger.redactURL(url))")
            AgentDebugLog.write(
                hypothesisId: "H1",
                location: "TorrentPlaybackCoordinator.swift:finishPlayback",
                message: "registry lookup returned nil",
                data: ["urlHost": url.host ?? ""]
            )
        }
        let loadPayload = (
            url: url,
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
            knownDuration: knownDurationSeconds,
            resourceLoader: resourceLoader
        )
        Task { @MainActor in
            await Task.yield()
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
        knownDurationSeconds: Double? = nil
    ) {
        configureSources(on: playerState, torrents: allTorrents, selected: torrent)

        let localURL = URL(fileURLWithPath: localFilePath)
        PlaybackLog.log("playLocalFile → loading player localURL=\(MovieBoxFileLogger.redactURL(localURL)) movieId=\(movieId) hdr=\(torrent.hdrType?.rawValue ?? "none")")
        let hudTitle = displayTitle.map { PlaybackDisplayTitle.clean($0) }
        let loadPayload = (
            url: localURL,
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
            knownDuration: knownDurationSeconds
        )
        Task { @MainActor in
            await Task.yield()
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
                knownDurationSeconds: loadPayload.knownDuration
            )
        }
    }

    func switchToSource(id: String, playerState: PlayerState, subtitleAppearance: SubtitleAppearance = .cinematic) async {
        guard let torrent = torrents.first(where: { $0.id.uuidString == id }) else { return }
        guard torrent.id.uuidString != playerState.selectedPlaybackSourceID else { return }

        let savedTime = playerState.currentTime
        let movieId = playerState.movieId
        let subtitleURL = playerState.subtitleURL

        playerState.isSwitchingSource = true
        await session?.cancel()

        if let infoHash = torrent.resolvedInfoHash,
           let localPath = downloadPersistence?.completedFilePath(for: infoHash) {
            let localURL = URL(fileURLWithPath: localPath)
            playerState.selectedPlaybackSourceID = id
            playerState.load(
                url: localURL,
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
            playerState.isSwitchingSource = false
            return
        }

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
