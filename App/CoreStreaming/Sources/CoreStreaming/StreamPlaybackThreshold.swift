import Foundation

public enum StreamPlaybackThreshold {
  /// Legacy head threshold (progress UI). FINDINGS Tier 1 opens AVPlayer once piece 0 is verified.
  public static let minimumHeadBytes: Int64 = 192 * 1024

  /// MKV open validates the first cluster referenced by Cues — typically 512KB–2MB into HEVC encodes.
  public static let minimumHeadBytesForMKV: Int64 = 3 * 1024 * 1024
}
