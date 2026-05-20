import CoreTorrent
import Foundation

/// Filters indexer results on movie detail pages: keeps likely full-length releases for the
/// requested title/year/runtime; drops TV episodes, clips, and size mismatches.
public enum TorrentMovieRelevanceFilter {
    /// Acceptable deviation between TMDB runtime and size-inferred playback length.
    public static let runtimeBufferMinutes = 5

    /// Single-token titles need an explicit release year in the torrent name (any film).
    private static let ambiguousTitleMaxLength = 12

    private static let nonMovieMarkers = [
        "daily show", "jimmy kimmel", "late show", "tonight show", "fallon", "conan", "colbert",
        "ellen", "talk show", "snl", "saturday night live", "last week tonight", "real time with",
        "podcast", "interview", "unrated clip", "bonus feature", "behind the scenes",
        "deleted scene", "gag reel", "featurette", "after show",
    ]

    private static let tvEpisodePattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\bS\d{1,2}E\d{2,4}\b"#, options: .caseInsensitive)
    }()

    private static let tvSeasonEpisodePattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\b\d{1,2}[xX]\d{2,3}\b"#, options: [])
    }()

    public static func filter(
        _ results: [TorrentResult],
        movieTitle: String,
        year: Int?,
        runtimeMinutes: Int? = nil
    ) -> [TorrentResult] {
        guard !results.isEmpty else { return results }

        let movieTokens = titleTokens(movieTitle)

        let scored: [(torrent: TorrentResult, score: Int)] = results.compactMap { torrent in
            let score = relevanceScore(
                title: torrent.title,
                movieTokens: movieTokens,
                year: year,
                sizeBytes: torrent.sizeBytes,
                runtimeMinutes: runtimeMinutes
            )
            guard score > 0 else { return nil }
            return (torrent, score)
        }

        if !scored.isEmpty {
            return scored.sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.torrent.seeders != rhs.torrent.seeders { return lhs.torrent.seeders > rhs.torrent.seeders }
                return lhs.torrent.sizeBytes > rhs.torrent.sizeBytes
            }.map(\.torrent)
        }

        let soft = results.filter { torrent in
            !isHardExcluded(
                title: torrent.title,
                movieTokens: movieTokens,
                sizeBytes: torrent.sizeBytes,
                runtimeMinutes: runtimeMinutes
            )
        }
        return soft.isEmpty ? results : soft
    }

    // MARK: - Scoring

    private static func relevanceScore(
        title: String,
        movieTokens: [String],
        year: Int?,
        sizeBytes: Int64,
        runtimeMinutes: Int?
    ) -> Int {
        if isHardExcluded(title: title, movieTokens: movieTokens, sizeBytes: sizeBytes, runtimeMinutes: runtimeMinutes) {
            return 0
        }

        let normalized = normalize(title)
        guard !movieTokens.isEmpty else { return 1 }

        var score = 0

        if matchesTitlePrefix(normalized, movieTokens: movieTokens) {
            score += 80
        } else if containsAllTokens(normalized, tokens: movieTokens) {
            score += 40
        } else {
            return 0
        }

        switch yearMatchScore(normalized: normalized, year: year, movieTokens: movieTokens) {
        case .match: score += 35
        case .weak: score += 15
        case .mismatch: return 0
        case .missing: break
        }

        if let runtimeMinutes, matchesExpectedRuntime(
            sizeBytes: sizeBytes,
            normalized: normalized,
            runtimeMinutes: runtimeMinutes
        ) {
            score += 20
        } else if runtimeMinutes != nil, sizeBytes > 0 {
            return 0
        } else if looksLikeFeatureFilm(sizeBytes: sizeBytes, normalized: normalized) {
            score += 10
        }

        if normalized.contains("webrip") || normalized.contains("bluray") || normalized.contains("remux") {
            score += 8
        }
        if normalized.contains("hdts") || normalized.contains("telesync") || normalized.contains(" cam ") {
            score -= 20
        }

        return score
    }

    private enum YearMatchScore {
        case match, weak, mismatch, missing
    }

    private static func yearMatchScore(
        normalized: String,
        year: Int?,
        movieTokens: [String]
    ) -> YearMatchScore {
        guard let year else { return .missing }

        if let releaseYear = parseReleaseYear(from: normalized) {
            if abs(releaseYear - year) <= 1 { return .match }
            if abs(releaseYear - year) > 3 { return .mismatch }
            return .weak
        }

        if normalized.contains(String(year)) { return .weak }

        if isAmbiguousTitle(movieTokens) {
            return .mismatch
        }

        return .missing
    }

    // MARK: - Hard excludes

    private static func isHardExcluded(
        title: String,
        movieTokens: [String],
        sizeBytes: Int64,
        runtimeMinutes: Int?
    ) -> Bool {
        let normalized = normalize(title)

        if isNonMovieContent(normalized) { return true }
        if isTVEpisode(normalized) { return true }
        if isAmbiguousTitleCollision(normalized, movieTokens: movieTokens) { return true }
        if isUnrelatedSubject(normalized, movieTokens: movieTokens) { return true }
        if let runtimeMinutes,
           sizeBytes > 0,
           isImplausibleDuration(sizeBytes: sizeBytes, normalized: normalized, runtimeMinutes: runtimeMinutes) {
            return true
        }

        return false
    }

    // MARK: - Runtime vs file size

    static func matchesExpectedRuntime(
        sizeBytes: Int64,
        normalized: String,
        runtimeMinutes: Int
    ) -> Bool {
        guard sizeBytes > 0, runtimeMinutes >= 15 else { return true }
        let bounds = bitrateBoundsBps(normalized: normalized)
        let expectedSeconds = Double(runtimeMinutes * 60)
        let buffer = Double(runtimeBufferMinutes * 60)
        let windowMin = max(60, expectedSeconds - buffer)
        let windowMax = expectedSeconds + buffer

        let estMinSeconds = Double(sizeBytes * 8) / bounds.high
        let estMaxSeconds = Double(sizeBytes * 8) / bounds.low
        return estMaxSeconds >= windowMin && estMinSeconds <= windowMax
    }

    private static func isImplausibleDuration(
        sizeBytes: Int64,
        normalized: String,
        runtimeMinutes: Int
    ) -> Bool {
        !matchesExpectedRuntime(sizeBytes: sizeBytes, normalized: normalized, runtimeMinutes: runtimeMinutes)
    }

    private struct BitrateBounds {
        let low: Double
        let high: Double
    }

    private static func bitrateBoundsBps(normalized: String) -> BitrateBounds {
        if normalized.contains("2160p") || normalized.contains("4k") {
            return BitrateBounds(low: 8_000_000, high: 45_000_000)
        }
        if normalized.contains("1080p") {
            if normalized.contains("h265") || normalized.contains("hevc") || normalized.contains("x265") {
                return BitrateBounds(low: 1_500_000, high: 12_000_000)
            }
            return BitrateBounds(low: 2_500_000, high: 15_000_000)
        }
        if normalized.contains("720p") {
            return BitrateBounds(low: 1_000_000, high: 8_000_000)
        }
        if normalized.contains("480p") || normalized.contains("360p") {
            return BitrateBounds(low: 500_000, high: 2_500_000)
        }
        return BitrateBounds(low: 2_000_000, high: 12_000_000)
    }

    // MARK: - Content classifiers (all movies)

    private static func isNonMovieContent(_ normalized: String) -> Bool {
        if nonMovieMarkers.contains(where: { normalized.contains($0) }) { return true }
        if normalized.contains(" host ") || normalized.hasPrefix("host ") { return true }
        return false
    }

    private static func isTVEpisode(_ normalized: String) -> Bool {
        let range = NSRange(normalized.startIndex..., in: normalized)
        if let tvEpisodePattern, tvEpisodePattern.firstMatch(in: normalized, options: [], range: range) != nil {
            return true
        }
        if let tvSeasonEpisodePattern, tvSeasonEpisodePattern.firstMatch(in: normalized, options: [], range: range) != nil {
            return true
        }
        if normalized.contains("season ") && normalized.contains("episode") { return true }
        return false
    }

    /// One-word (or very short) film titles: drop releases where the token is only a substring/guest name.
    private static func isAmbiguousTitleCollision(_ normalized: String, movieTokens: [String]) -> Bool {
        guard isAmbiguousTitle(movieTokens), let primary = movieTokens.first?.lowercased() else {
            return false
        }

        let words = normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for word in words {
            let lower = word.lowercased()
            if lower.count > primary.count, lower.hasPrefix(primary) {
                return true
            }
        }

        if let regex = try? NSRegularExpression(
            pattern: #"\b"# + NSRegularExpression.escapedPattern(for: primary) + #"\s+[a-z]{2,}\b"#,
            options: .caseInsensitive
        ) {
            let range = NSRange(normalized.startIndex..., in: normalized)
            if regex.firstMatch(in: normalized, options: [], range: range) != nil {
                return true
            }
        }

        return false
    }

    /// Release is clearly about something else (doc / making-of) that only mentions the search token.
    private static func isUnrelatedSubject(_ normalized: String, movieTokens: [String]) -> Bool {
        guard !matchesTitlePrefix(normalized, movieTokens: movieTokens) else { return false }

        let markers = ["becoming ", "the making of ", "documentary", "biography", "chronicles "]
        guard markers.contains(where: { normalized.contains($0) }) else { return false }

        return containsAllTokens(normalized, tokens: movieTokens)
    }

    private static func isAmbiguousTitle(_ movieTokens: [String]) -> Bool {
        movieTokens.count == 1 && movieTokens[0].count <= ambiguousTitleMaxLength
    }

    // MARK: - Title matching

    private static func matchesTitlePrefix(_ normalized: String, movieTokens: [String]) -> Bool {
        let joined = movieTokens.joined(separator: " ")
        if normalized.hasPrefix(joined) || normalized.hasPrefix("the \(joined)") {
            return true
        }

        let dotted = movieTokens.joined(separator: ".")
        if normalized.hasPrefix(dotted) || normalized.hasPrefix("the.\(dotted)") {
            return true
        }

        return false
    }

    private static func containsAllTokens(_ normalized: String, tokens: [String]) -> Bool {
        let dotted = normalized.replacingOccurrences(of: " ", with: ".")
        return tokens.allSatisfy { token in
            let lower = token.lowercased()
            return normalized.contains(lower) || dotted.contains(lower)
        }
    }

    private static func titleTokens(_ movieTitle: String) -> [String] {
        normalize(movieTitle)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseReleaseYear(from normalized: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(19|20)\d{2}\b"#, options: []) else {
            return nil
        }
        let range = NSRange(normalized.startIndex..., in: normalized)
        guard let match = regex.firstMatch(in: normalized, options: [], range: range),
              let yearRange = Range(match.range, in: normalized)
        else { return nil }
        return Int(normalized[yearRange])
    }

    private static func looksLikeFeatureFilm(sizeBytes: Int64, normalized: String) -> Bool {
        guard sizeBytes > 0 else { return true }
        if normalized.contains("480p") || normalized.contains("360p") {
            return sizeBytes >= 200_000_000
        }
        return sizeBytes >= 400_000_000
    }
}
