import CorePlayer
import CoreStreaming
import CoreTorrent
import Foundation

public enum TorrentPlaybackService {
  @MainActor private static var bufferingMonitorTask: Task<Void, Never>?
  public struct Request: Sendable {
    let torrent: TorrentResult
    let allTorrents: [TorrentResult]
    let movieId: Int
    let subtitleURL: URL?
    let playback: PlaybackSettings
    let episodeTitle: String?
    let displayTitle: String?
    let resumePosition: Double?
    let waitTimeout: TimeInterval

    public init(
      torrent: TorrentResult,
      allTorrents: [TorrentResult]? = nil,
      movieId: Int,
      subtitleURL: URL? = nil,
      playback: PlaybackSettings,
      episodeTitle: String? = nil,
      displayTitle: String? = nil,
      resumePosition: Double? = nil,
      waitTimeout: TimeInterval = 180
    ) {
      self.torrent = torrent
      self.allTorrents = allTorrents ?? [torrent]
      self.movieId = movieId
      self.subtitleURL = subtitleURL
      self.playback = playback
      self.episodeTitle = episodeTitle
      self.displayTitle = displayTitle
      self.resumePosition = resumePosition
      self.waitTimeout = waitTimeout
    }
  }

  @MainActor
  public static func play(
    request: Request,
    appServices: AppServices,
    playerState: PlayerState
  ) async throws {
    PlaybackLog.log(
      "play(single) movieId=\(request.movieId) torrent=\"\(request.torrent.title)\" waitTimeout=\(Int(request.waitTimeout))s"
    )
    let coordinator = appServices.beginPlaybackCoordinator()
    let session = await coordinator.startSession(for: request.torrent)
    appServices.registerActiveSession(session)

    await session.waitForPlayback(timeout: request.waitTimeout)

    if case .failed(let message) = session.state {
      PlaybackLog.error("play(single) stream failed — \(message)")
      throw TorrentPlaybackError.streamingFailed(message)
    }
    guard case .ready = session.state else {
      PlaybackLog.error("play(single) stream not ready — state=\(session.stateLabel)")
      throw TorrentPlaybackError.streamingFailed("Stream did not become ready.")
    }

    try coordinator.finishPlayback(
      torrent: request.torrent,
      allTorrents: request.allTorrents,
      session: session,
      playerState: playerState,
      movieId: request.movieId,
      subtitleURL: request.subtitleURL,
      subtitleAppearance: request.playback.appearance,
      subtitleFontSize: request.playback.fontSize,
      episodeTitle: request.episodeTitle,
      displayTitle: request.displayTitle,
      resumePosition: request.resumePosition
    )
  }

  /// Tries torrents in order until one streams successfully (detail "Play Now").
  @MainActor
  public static func playBestAvailable(
    torrents: [TorrentResult],
    movieId: Int,
    subtitleURL: URL?,
    playback: PlaybackSettings,
    episodeTitle: String?,
    displayTitle: String? = nil,
    resumePosition: Double? = nil,
    appServices: AppServices,
    playerState: PlayerState,
    onSessionStarted: @MainActor (TorrentStreamSession) -> Void = { _ in },
    maxAttempts: Int = 8,
    waitTimeout: TimeInterval = 180
  ) async throws {
    let seeded = torrents.filter { $0.seeders > 0 }
    let candidates = seeded.isEmpty ? torrents : seeded
    let ordered = candidates.sorted { lhs, rhs in
      if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
      if lhs.seeders != rhs.seeders { return lhs.seeders > rhs.seeders }
      return lhs.sizeBytes > rhs.sizeBytes
    }

    PlaybackLog.log(
      "playBestAvailable movieId=\(movieId) candidates=\(ordered.count) maxAttempts=\(maxAttempts) waitTimeout=\(Int(waitTimeout))s subtitle=\(subtitleURL != nil)"
    )

    playerState.beginBufferingPlayback(
      title: ordered.first?.title ?? "Playing",
      movieId: movieId,
      subtitleAppearance: playback.appearance,
      subtitleFontSize: playback.fontSize,
      episodeTitle: episodeTitle,
      displayTitle: displayTitle
    )

    let coordinator = appServices.beginPlaybackCoordinator()
    var lastError: String?
    var attempt = 0

    for torrent in ordered.prefix(maxAttempts) {
      attempt += 1
      await coordinator.cancel()
      PlaybackLog.log(
        "attempt \(attempt)/\(min(maxAttempts, ordered.count)) — \"\(torrent.title)\" \(torrent.quality.rawValue) seeders=\(torrent.seeders) size=\(torrent.sizeBytes)"
      )
      let session = await coordinator.startSession(for: torrent)
      onSessionStarted(session)
      appServices.registerActiveSession(session)
      startBufferingMonitor(session: session, playerState: playerState)

      await session.waitForPlayback(timeout: waitTimeout)
      stopBufferingMonitor()

      if case .failed(let err) = session.state {
        PlaybackLog.warn("attempt \(attempt) failed — \(err)")
        lastError = err
        continue
      }
      guard case .ready = session.state else {
        PlaybackLog.warn("attempt \(attempt) not ready after wait — state=\(session.stateLabel)")
        lastError = "Stream did not become ready."
        continue
      }

      PlaybackLog.log("attempt \(attempt) ready — loading AVPlayer")
      try coordinator.finishPlayback(
        torrent: torrent,
        allTorrents: torrents,
        session: session,
        playerState: playerState,
        movieId: movieId,
        subtitleURL: subtitleURL,
        subtitleAppearance: playback.appearance,
        subtitleFontSize: playback.fontSize,
        episodeTitle: episodeTitle,
        displayTitle: displayTitle,
        resumePosition: resumePosition
      )
      PlaybackLog.log("playBestAvailable succeeded on attempt \(attempt)")
      return
    }

    stopBufferingMonitor()
    playerState.dismiss()

    let summary = lastError ?? "Could not prepare any release for streaming. Try another version."
    PlaybackLog.error("playBestAvailable exhausted — \(summary)")
    throw TorrentPlaybackError.streamingFailed(summary)
  }

  @MainActor
  private static func startBufferingMonitor(session: TorrentStreamSession, playerState: PlayerState) {
    bufferingMonitorTask?.cancel()
    bufferingMonitorTask = Task { @MainActor in
      while !Task.isCancelled {
        switch session.state {
        case .preparing:
          playerState.updateBufferingDetail(
            "Connecting… \(session.peerCount) peers (swarm \(session.swarmSeeders) seeders)"
          )
        case .buffering(let progress):
          playerState.updateBufferingDetail(
            "\(session.peerCount) peers · \(Int(progress * 100))% buffered"
          )
        case .ready:
          playerState.updateBufferingDetail("Starting playback…")
          return
        case .failed, .cancelled, .idle:
          return
        }
        try? await Task.sleep(for: .milliseconds(350))
      }
    }
  }

  @MainActor
  private static func stopBufferingMonitor() {
    bufferingMonitorTask?.cancel()
    bufferingMonitorTask = nil
  }
}
