import Foundation

public enum StreamPlaybackThreshold {
  /// Minimum contiguous bytes at the media head before the UI may start AVPlayer.
  public static let minimumHeadBytes: Int64 = 192 * 1024

  /// MKV open validates the first cluster referenced by Cues — typically 512KB–2MB into HEVC encodes.
  public static let minimumHeadBytesForMKV: Int64 = 3 * 1024 * 1024
}
