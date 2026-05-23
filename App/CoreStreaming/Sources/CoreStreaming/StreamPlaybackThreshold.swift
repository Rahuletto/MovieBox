import Foundation

public enum StreamPlaybackThreshold {
  /// Legacy head threshold (progress UI).
  public static let minimumHeadBytes: Int64 = 192 * 1024

  /// MP4: AVPlayer reads ftyp/mdat and bytes through ~3.5MB before tail moov (moviebox.log port 65209).
  public static let minimumContiguousHeadBytesForMP4: Int64 = 4 * 1024 * 1024

  /// MKV open validates the first cluster referenced by Cues — typically 512KB–2MB into HEVC encodes.
  public static let minimumHeadBytesForMKV: Int64 = 3 * 1024 * 1024
}
