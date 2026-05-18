import CorePlayer
import CoreStreaming
import CoreTorrent
import Foundation

public enum TorrentPlaybackService {
  public struct Request: Sendable {
    let torrent: TorrentResult
    let allTorrents: [TorrentResult]
    let movieId: Int
    let subtitleURL: URL?
    let playback: PlaybackSettings
    let episodeTitle: String?
    let waitTimeout: TimeInterval

    public init(
      torrent: TorrentResult,
      allTorrents: [TorrentResult]? = nil,
      movieId: Int,
      subtitleURL: URL? = nil,
      playback: PlaybackSettings,
      episodeTitle: String? = nil,
      waitTimeout: TimeInterval = 180
    ) {
      self.torrent = torrent
      self.allTorrents = allTorrents ?? [torrent]
      self.movieId = movieId
      self.subtitleURL = subtitleURL
      self.playback = playback
      self.episodeTitle = episodeTitle
      self.waitTimeout = waitTimeout
    }
  }

  @MainActor
  public static func play(
    request: Request,
    appServices: AppServices,
    playerState: PlayerState
  ) async throws {
    let coordinator = appServices.beginPlaybackCoordinator()
    let session = await coordinator.startSession(for: request.torrent)
    appServices.registerActiveSession(session)

    await session.waitForPlayback(timeout: request.waitTimeout)

    if case .failed(let message) = session.state {
      throw TorrentPlaybackError.streamingFailed(message)
    }
    guard case .ready = session.state else {
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
      episodeTitle: request.episodeTitle
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

    let coordinator = appServices.beginPlaybackCoordinator()
    var lastError: String?

    for torrent in ordered.prefix(maxAttempts) {
      await coordinator.cancel()
      let session = await coordinator.startSession(for: torrent)
      onSessionStarted(session)
      appServices.registerActiveSession(session)

      await session.waitForPlayback(timeout: waitTimeout)

      if case .failed(let err) = session.state {
        lastError = err
        continue
      }
      guard case .ready = session.state else {
        lastError = "Stream did not become ready."
        continue
      }

      try coordinator.finishPlayback(
        torrent: torrent,
        allTorrents: torrents,
        session: session,
        playerState: playerState,
        movieId: movieId,
        subtitleURL: subtitleURL,
        subtitleAppearance: playback.appearance,
        subtitleFontSize: playback.fontSize,
        episodeTitle: episodeTitle
      )
      return
    }

    throw TorrentPlaybackError.streamingFailed(
      lastError ?? "Could not prepare any release for streaming. Try another version."
    )
  }
}
