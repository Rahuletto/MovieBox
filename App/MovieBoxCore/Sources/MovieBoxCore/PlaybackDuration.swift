import Foundation

/// Picks the best full-length duration for the scrubber (TMDB/runtime beats partial HLS windows).
public enum PlaybackDuration {
    public static func resolved(known: Double?, probed: Double?, remux: Double? = nil) -> Double? {
        let candidates = [known, probed, remux].compactMap { $0 }.filter { $0.isFinite && $0 > 60 }
        return candidates.max()
    }
}
