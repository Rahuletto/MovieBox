import CoreMetadata
import CorePlayer
import CoreStreaming
import CoreTorrent
import Foundation

public enum TorrentPlaybackService {
  @MainActor
  public static func play(
    request: TorrentPlaybackService.Request,
    appServices: AppServices,
    playerState: PlayerState
  ) async throws {
    let persistentRequest = PersistentPlaybackStartRequest(
      mode: .single(request.torrent),
      movieId: request.movieId,
      mediaKind: .movie,
      allTorrents: request.allTorrents,
      posterURL: nil,
      title: request.torrent.title,
      episodeTitle: request.episodeTitle,
      displayTitle: request.displayTitle,
      subtitleURL: request.subtitleURL,
      playback: request.playback,
      resumePosition: request.resumePosition,
      knownDurationSeconds: request.knownDurationSeconds,
      waitTimeout: request.waitTimeout,
      onSessionStarted: { session in
        request.onBufferingUpdate?(.starting)
        Task { @MainActor in
          await observeRowBuffering(session: session, onUpdate: request.onBufferingUpdate)
        }
      }
    )

    let result = appServices.persistentPlayback.start(
      request: persistentRequest,
      appServices: appServices,
      playerState: playerState
    )

    if result == .needsConfirmation {
      throw TorrentPlaybackError.streamingFailed("Another stream is already preparing.")
    }

    try await appServices.persistentPlayback.waitUntilSettled()
  }

  /// Tries torrents in order until one streams successfully (detail "Play Now").
  @MainActor
  public static func playBestAvailable(
    torrents: [TorrentResult],
    movieId: Int,
    mediaKind: MediaKind = .movie,
    posterURL: URL? = nil,
    subtitleURL: URL?,
    playback: PlaybackSettings,
    episodeTitle: String?,
    displayTitle: String? = nil,
    resumePosition: Double? = nil,
    knownDurationSeconds: Double? = nil,
    appServices: AppServices,
    playerState: PlayerState,
    onSessionStarted: @escaping @MainActor (TorrentStreamSession) -> Void = { _ in },
    maxAttempts: Int = 8,
    waitTimeout: TimeInterval = 180
  ) async throws {
    let ordered = PersistentPlaybackStartRequest.orderedCandidates(from: torrents)
    guard let first = ordered.first else {
      throw TorrentPlaybackError.streamingFailed("No releases available.")
    }

    PlaybackLog.log(
      "playBestAvailable movieId=\(movieId) candidates=\(ordered.count) maxAttempts=\(maxAttempts)"
    )

    let persistentRequest = PersistentPlaybackStartRequest(
      mode: .bestAvailable(torrents: torrents, maxAttempts: maxAttempts),
      movieId: movieId,
      mediaKind: mediaKind,
      allTorrents: torrents,
      posterURL: posterURL,
      title: first.title,
      episodeTitle: episodeTitle,
      displayTitle: displayTitle,
      subtitleURL: subtitleURL,
      playback: playback,
      resumePosition: resumePosition,
      knownDurationSeconds: knownDurationSeconds,
      waitTimeout: waitTimeout,
      onSessionStarted: onSessionStarted
    )

    let result = appServices.persistentPlayback.start(
      request: persistentRequest,
      appServices: appServices,
      playerState: playerState
    )

    if result == .needsConfirmation {
      throw TorrentPlaybackError.streamingFailed("Another stream is already preparing.")
    }

    try await appServices.persistentPlayback.waitUntilSettled()
  }

  @MainActor
  private static func observeRowBuffering(
    session: TorrentStreamSession,
    onUpdate: (@MainActor (TorrentRowBufferingSnapshot) -> Void)?
  ) async {
    guard let onUpdate else { return }
    while !Task.isCancelled {
      onUpdate(await session.rowBufferingSnapshot())
      switch session.state {
      case .ready, .failed, .cancelled:
        return
      default:
        break
      }
      try? await Task.sleep(for: .milliseconds(200))
    }
  }

  public struct Request: Sendable {
    let torrent: TorrentResult
    let allTorrents: [TorrentResult]
    let movieId: Int
    let subtitleURL: URL?
    let playback: PlaybackSettings
    let episodeTitle: String?
    let displayTitle: String?
    let resumePosition: Double?
    let knownDurationSeconds: Double?
    let waitTimeout: TimeInterval
    let onBufferingUpdate: (@MainActor (TorrentRowBufferingSnapshot) -> Void)?

    public init(
      torrent: TorrentResult,
      allTorrents: [TorrentResult]? = nil,
      movieId: Int,
      subtitleURL: URL? = nil,
      playback: PlaybackSettings,
      episodeTitle: String? = nil,
      displayTitle: String? = nil,
      resumePosition: Double? = nil,
      knownDurationSeconds: Double? = nil,
      waitTimeout: TimeInterval = 180,
      onBufferingUpdate: (@MainActor (TorrentRowBufferingSnapshot) -> Void)? = nil
    ) {
      self.torrent = torrent
      self.allTorrents = allTorrents ?? [torrent]
      self.movieId = movieId
      self.subtitleURL = subtitleURL
      self.playback = playback
      self.episodeTitle = episodeTitle
      self.displayTitle = displayTitle
      self.resumePosition = resumePosition
      self.knownDurationSeconds = knownDurationSeconds
      self.waitTimeout = waitTimeout
      self.onBufferingUpdate = onBufferingUpdate
    }
  }
}
