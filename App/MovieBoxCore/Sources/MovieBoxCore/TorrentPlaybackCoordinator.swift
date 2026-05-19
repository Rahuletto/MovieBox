import CorePlayer
import CoreStorage
import CoreStreaming
import CoreTorrent
import Foundation

@MainActor
public final class TorrentPlaybackCoordinator {
    private let orchestrator: StreamingOrchestrator
    private(set) var session: TorrentStreamSession?
    private(set) var torrents: [TorrentResult] = []

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
        episodeTitle: String? = nil
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
        playerState.load(
            url: url,
            title: torrent.title,
            movieId: movieId,
            subtitleURL: subtitleURL,
            hdrType: playerHDRType(from: torrent.hdrType),
            subtitleAppearance: subtitleAppearance,
            subtitleFontSize: subtitleFontSize,
            episodeTitle: episodeTitle
        )
    }

    func switchToSource(id: String, playerState: PlayerState, subtitleAppearance: SubtitleAppearance = .cinematic) async {
        guard let torrent = torrents.first(where: { $0.id.uuidString == id }) else { return }
        guard torrent.id.uuidString != playerState.selectedPlaybackSourceID else { return }

        let savedTime = playerState.currentTime
        let movieId = playerState.movieId
        let subtitleURL = playerState.subtitleURL

        playerState.isSwitchingSource = true
        await session?.cancel()

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
                subtitleAppearance: subtitleAppearance,
                subtitleFontSize: playerState.subtitleFontSize
            )
            if savedTime > 1 {
                playerState.seek(to: savedTime)
            }
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
