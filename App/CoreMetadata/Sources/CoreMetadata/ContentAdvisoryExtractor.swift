import Foundation

/// Parses TMDB regional content descriptors (release_dates / content_ratings).
enum ContentAdvisoryExtractor {
    private static let preferredRegions = ["US", "GB", "CA", "AU", "IE", "NZ", "DE", "FR"]
    /// Theatrical wide release in TMDB release_dates.
    private static let theatricalReleaseType = 3

    static func fromMovieReleaseDates(_ countries: [TMDBReleaseDatesCountryDTO]?) -> [String] {
        guard let countries, !countries.isEmpty else { return [] }
        var ordered: [String] = []
        var seen = Set<String>()

        for iso in preferredRegions {
            appendDescriptors(from: countries, iso: iso, preferTheatrical: true, into: &ordered, seen: &seen)
        }
        for country in countries {
            appendDescriptors(from: [country], iso: country.iso31661, preferTheatrical: true, into: &ordered, seen: &seen)
        }
        return ordered
    }

    static func fromTVContentRatings(_ ratings: [TMDBContentRatingDTO]?) -> [String] {
        guard let ratings, !ratings.isEmpty else { return [] }
        var ordered: [String] = []
        var seen = Set<String>()

        for iso in preferredRegions {
            guard let row = ratings.first(where: { $0.iso31661 == iso }) else { continue }
            appendRawDescriptors(row.descriptors ?? [], into: &ordered, seen: &seen)
        }
        for row in ratings {
            appendRawDescriptors(row.descriptors ?? [], into: &ordered, seen: &seen)
        }
        return ordered
    }

    /// Normalizes a TMDB descriptor into one or more display categories (Apple TV+ style).
    static func categoryLabels(for raw: String) -> [String] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if text.lowercased().hasPrefix("contains ") {
            text = String(text.dropFirst("contains ".count)).trimmingCharacters(in: .whitespaces)
        }

        return text
            .replacingOccurrences(of: " / ", with: "/")
            .split(separator: "/")
            .flatMap { segment -> [String] in
                segment
                    .split(separator: ",")
                    .compactMap { part in
                        let normalized = normalizeCategory(String(part).trimmingCharacters(in: .whitespaces))
                        return normalized.isEmpty ? nil : normalized
                    }
            }
    }

    static func normalizeCategory(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let key = trimmed.lowercased()
        if let mapped = knownMappings[key] { return mapped }
        return titleCase(trimmed)
    }

    private static let knownMappings: [String: String] = [
        "language": "Language",
        "profanity": "Language",
        "alcohol": "Alcohol Consumption",
        "alcohol consumption": "Alcohol Consumption",
        "drugs": "Drugs or Drug Use",
        "drug use": "Drugs or Drug Use",
        "drugs or drug use": "Drugs or Drug Use",
        "violence": "Violence",
        "graphic violence": "Graphic Violence",
        "sexuality": "Sexual Content",
        "sexual content": "Sexual Content",
        "sex": "Sexual Content",
        "nudity": "Nudity",
        "horror": "Horror",
        "smoking": "Smoking or Tobacco Use",
        "tobacco": "Smoking or Tobacco Use",
        "smoking or tobacco use": "Smoking or Tobacco Use",
        "threat": "Violence",
        "stressful scenes": "Horror",
        "may cause anxiety": "Horror",
        "fear": "Horror",
        "negative examples": "Violence",
        "v": "Violence",
    ]

    private static func titleCase(_ value: String) -> String {
        value.split(separator: " ")
            .map { word in
                let lower = word.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func appendDescriptors(
        from countries: [TMDBReleaseDatesCountryDTO],
        iso: String?,
        preferTheatrical: Bool,
        into ordered: inout [String],
        seen: inout Set<String>
    ) {
        guard let iso, let country = countries.first(where: { $0.iso31661 == iso }) else { return }
        let releases = country.releaseDates ?? []
        let filtered = preferTheatrical
            ? releases.filter { $0.type == theatricalReleaseType }
            : releases
        let source = filtered.isEmpty ? releases : filtered
        for release in source {
            appendRawDescriptors(release.descriptors ?? [], into: &ordered, seen: &seen)
        }
    }

    private static func appendRawDescriptors(
        _ descriptors: [String],
        into ordered: inout [String],
        seen: inout Set<String>
    ) {
        for raw in descriptors {
            for label in categoryLabels(for: raw) {
                let key = label.lowercased()
                guard seen.insert(key).inserted else { continue }
                ordered.append(label)
            }
        }
    }
}

struct TMDBReleaseDatesCountryDTO: Decodable, Sendable {
    let iso31661: String?
    let releaseDates: [TMDBReleaseDateEntryDTO]?
}

struct TMDBReleaseDateEntryDTO: Decodable, Sendable {
    let certification: String?
    let descriptors: [String]?
    let type: Int?
}

struct TMDBContentRatingDTO: Decodable, Sendable {
    let descriptors: [String]?
    let iso31661: String?
    let rating: String?
}

struct TMDBReleaseDatesAppendDTO: Decodable, Sendable {
    let results: [TMDBReleaseDatesCountryDTO]?
}

struct TMDBContentRatingsAppendDTO: Decodable, Sendable {
    let results: [TMDBContentRatingDTO]?
}
