import Foundation

public enum PlaybackDisplayTitle {
    /// Minimum saved position to count as "continue watching" (seconds).
    public static let minimumContinueSeconds: Double = 20

    /// Strips release tags like `[1080p]`, `[WEBRip]`, and `(2026)` from torrent titles.
    public static func clean(_ raw: String) -> String {
        var result = raw
        result = result.replacingOccurrences(of: #"\s*\[[^\]]+\]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s*\(\d{4}\)"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: ".", with: " ")
        result = result.replacingOccurrences(of: "_", with: " ")
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func hasContinueProgress(positionSeconds: Double, watchedFraction: Double = 0) -> Bool {
        positionSeconds > minimumContinueSeconds && watchedFraction < 0.95
    }
}
