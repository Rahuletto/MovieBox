import Foundation

/// Builds safe text queries for indexer APIs.
public enum TorrentSearchQuery {
    /// Strips `%` (printf-style corruption in some APIs/logs) and appends release year when known.
    public static func make(title: String, year: Int?) -> String {
        let cleaned = title
            .replacingOccurrences(of: "%", with: "")
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return title.trimmingCharacters(in: .whitespacesAndNewlines) }

        if let year, (1900...2100).contains(year) {
            return "\(cleaned) \(year)"
        }
        return cleaned
    }
}

public struct TorrentSearchDiagnostics: Sendable {
    public var queryUsed: String = ""
    public var torrentioAttempted: Bool = false
    public var torrentioCount: Int = 0
    public var torrentioError: String?
    public var ytsAttempted: Bool = false
    public var ytsCount: Int = 0
    public var ytsError: String?
    /// Per-indexer result counts (`yts`, `eztv`, `piratebay`, …).
    public var nativeCounts: [String: Int] = [:]
    public var nativeErrors: [String: String] = [:]

    public init() {}

    public var nativeTotalCount: Int {
        nativeCounts.values.reduce(0, +)
    }

    public var totalCount: Int {
        torrentioCount + nativeTotalCount
    }
}
