import Foundation

public enum StreamPlaybackThreshold {
  /// Minimum contiguous bytes at the media head before the UI may start AVPlayer.
  public static let minimumHeadBytes: Int64 = 192 * 1024
}
