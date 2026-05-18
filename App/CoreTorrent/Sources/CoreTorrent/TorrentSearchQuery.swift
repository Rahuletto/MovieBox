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

    /// TV episode search — e.g. `Breaking Bad S01E03`.
    public static func makeEpisode(showTitle: String, season: Int, episode: Int, year: Int? = nil) -> String {
        let cleaned = showTitle
            .replacingOccurrences(of: "%", with: "")
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let seasonText = String(format: "%02d", max(season, 0))
        let episodeText = String(format: "%02d", max(episode, 0))
        let base = "\(cleaned) S\(seasonText)E\(episodeText)"

        if let year, (1900...2100).contains(year) {
            return "\(base) \(year)"
        }
        return base
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

    /// User-facing copy for the torrent list when no results are shown.
    public func emptyListingMessage(title: String, isTV: Bool) -> String {
        if let backendError = nativeErrors["backend"], !backendError.isEmpty {
            return "Torrent search could not reach your MovieBox backend (\(backendError)). Open Settings → Metadata and confirm the proxy URL, app token, and that `wrangler dev` is running."
        }

        let sources = isTV
            ? "Torrentio, EZTV, 1337x, and Pirate Bay"
            : "Torrentio, YTS, 1337x, and Pirate Bay"

        if torrentioAttempted, torrentioCount == 0, let err = torrentioError, !err.isEmpty {
            return "No releases for \"\(title)\" yet. \(sources) were searched via your backend; Torrentio reported: \(err)."
        }

        return "No releases for \"\(title)\" turned up from \(sources) (searched through your backend). Check that the backend is running, then try again in a moment."
    }

    /// User-facing copy when Play is tapped but the torrent list is empty.
    public func playFailureMessage(title: String, isTV: Bool, missingImdb: Bool) -> String {
        if let backendError = nativeErrors["backend"], !backendError.isEmpty {
            return "Cannot play — backend torrent search is not configured or unreachable. \(backendError)"
        }

        if missingImdb {
            let kindLabel = isTV ? "this series" : "this film"
            return "Cannot play — no torrents found for \(kindLabel). Your metadata backend must supply an IMDb id so Torrentio can search."
        }

        return emptyListingMessage(title: title, isTV: isTV)
    }
}
