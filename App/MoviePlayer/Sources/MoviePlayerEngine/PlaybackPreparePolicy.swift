import Foundation

/// How a media file was prepared for AVPlayer.
public enum PlaybackPreparationMode: String, Sendable, Equatable {
    /// Compatible MP4/MOV/M4V loaded directly in AVPlayer.
    case nativePassthrough
    /// H.264/HEVC + AAC/AC-3/E-AC-3 repackaged to HLS with `-c copy`.
    case losslessHLS
    /// Re-encoded with VideoToolbox + AAC for AVPlayer compatibility.
    case transcodeHLS
}

public struct PlaybackPreparePolicy: Sendable {
    /// When true, unsupported codecs are hardware-transcoded to HLS instead of failing.
    public var allowTranscodeFallback: Bool

    public init(allowTranscodeFallback: Bool = true) {
        self.allowTranscodeFallback = allowTranscodeFallback
    }
}

public struct PlaybackPrepareResult: Sendable {
    public let playbackURL: URL
    public let mode: PlaybackPreparationMode
    public let remuxResult: RemuxResult?
    public let durationSeconds: Double?

    public init(
        playbackURL: URL,
        mode: PlaybackPreparationMode,
        remuxResult: RemuxResult? = nil,
        durationSeconds: Double? = nil
    ) {
        self.playbackURL = playbackURL
        self.mode = mode
        self.remuxResult = remuxResult
        self.durationSeconds = durationSeconds
    }
}
