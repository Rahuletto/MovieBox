import Foundation

public enum StreamPlaybackThreshold {
  /// Legacy head threshold (progress UI).
  public static let minimumHeadBytes: Int64 = 192 * 1024

  /// MP4: AVPlayer reads ftyp/mdat and bytes through ~3.5MB before tail moov (moviebox.log port 65209).
  public static let minimumContiguousHeadBytesForMP4: Int64 = 4 * 1024 * 1024

  /// MKV: verified head before opening AVPlayer (EBML + early clusters).
  public static let minimumHeadBytesForMKV: Int64 = 3 * 1024 * 1024

  /// MKV: contiguous readable head (moviebox.log — AVPlayer fails if clusters aren't on disk).
  public static let minimumContiguousHeadBytesForMKV: Int64 = 8 * 1024 * 1024

  /// MKV: readable Cues/index span at EOF before play (Interstellar log: tail=1/12 → -11828).
  public static let minimumMKVTailReadableBytes: Int64 = 8 * 1024 * 1024
}
