import Foundation

public struct PersonProfile: Sendable, Codable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let biography: String
    public let birthday: String?
    public let deathday: String?
    public let placeOfBirth: String?
    public let profilePath: String?
    public let knownForDepartment: String?
    public let homepage: String?

    public init(
        id: Int,
        name: String,
        biography: String,
        birthday: String? = nil,
        deathday: String? = nil,
        placeOfBirth: String? = nil,
        profilePath: String? = nil,
        knownForDepartment: String? = nil,
        homepage: String? = nil
    ) {
        self.id = id
        self.name = name
        self.biography = biography
        self.birthday = birthday
        self.deathday = deathday
        self.placeOfBirth = placeOfBirth
        self.profilePath = profilePath
        self.knownForDepartment = knownForDepartment
        self.homepage = homepage
    }

    public var displayAgeLine: String? {
        guard let birthday, birthday.count >= 4 else { return nil }
        let birthYear = birthday.prefix(4)
        if let deathday, deathday.count >= 4 {
            return "Born \(birthYear) · Died \(deathday.prefix(4))"
        }
        return "Born \(birthYear)"
    }
}

public struct PersonExternalLinks: Sendable, Codable, Hashable {
    public let imdbId: String?
    public let instagramId: String?
    public let twitterId: String?
    public let facebookId: String?

    public init(
        imdbId: String? = nil,
        instagramId: String? = nil,
        twitterId: String? = nil,
        facebookId: String? = nil
    ) {
        self.imdbId = imdbId
        self.instagramId = instagramId
        self.twitterId = twitterId
        self.facebookId = facebookId
    }

    public var hasAny: Bool {
        imdbId != nil || instagramId != nil || twitterId != nil || facebookId != nil
    }
}

public struct PersonCredit: Sendable, Codable, Identifiable, Hashable {
    public let id: Int
    public let title: String
    public let mediaKind: MediaKind
    public let character: String?
    public let job: String?
    public let posterPath: String?
    public let releaseDate: String
    public let voteAverage: Double
    public let voteCount: Int
    public let episodeCount: Int?

    public init(
        id: Int,
        title: String,
        mediaKind: MediaKind,
        character: String? = nil,
        job: String? = nil,
        posterPath: String? = nil,
        releaseDate: String = "",
        voteAverage: Double = 0,
        voteCount: Int = 0,
        episodeCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.mediaKind = mediaKind
        self.character = character
        self.job = job
        self.posterPath = posterPath
        self.releaseDate = releaseDate
        self.voteAverage = voteAverage
        self.voteCount = voteCount
        self.episodeCount = episodeCount
    }

    public var roleLine: String {
        if let character, !character.isEmpty { return character }
        if let job, !job.isEmpty { return job }
        return ""
    }

    public var displayYear: String {
        let year = releaseDate.prefix(4)
        return year.count == 4 ? String(year) : ""
    }

    public var sortYear: Int {
        Int(releaseDate.prefix(4)) ?? 0
    }
}

public struct PersonDetail: Sendable, Codable, Identifiable, Hashable {
    public var id: Int { profile.id }
    public let profile: PersonProfile
    public let credits: [PersonCredit]
    public let externalLinks: PersonExternalLinks

    public init(profile: PersonProfile, credits: [PersonCredit], externalLinks: PersonExternalLinks = PersonExternalLinks()) {
        self.profile = profile
        self.credits = credits
        self.externalLinks = externalLinks
    }

    public var knownForCredits: [PersonCredit] {
        Array(
            credits
                .sorted {
                    if $0.voteCount != $1.voteCount { return $0.voteCount > $1.voteCount }
                    return $0.voteAverage > $1.voteAverage
                }
                .prefix(12)
        )
    }

    public func credits(filter: PersonCreditFilter) -> [PersonCredit] {
        let filtered: [PersonCredit] = switch filter {
        case .all: credits
        case .movies: credits.filter { $0.mediaKind == .movie }
        case .tv: credits.filter { $0.mediaKind == .tv }
        }
        return filtered.sorted {
            if $0.sortYear != $1.sortYear { return $0.sortYear > $1.sortYear }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }
}

public enum PersonCreditFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case movies = "Movies"
    case tv = "TV"

    public var id: String { rawValue }
}

// MARK: - TMDB mapping

enum PersonDetailMapper {
    static func map(bundle: TMDBPersonBundleDTO) -> PersonDetail {
        let ext = bundle.externalIds
        let links = PersonExternalLinks(
            imdbId: ext?.imdbId,
            instagramId: ext?.instagramId,
            twitterId: ext?.twitterId,
            facebookId: ext?.facebookId
        )

        let castCredits = bundle.combinedCredits?.cast ?? []
        let credits = castCredits.compactMap { credit -> PersonCredit? in
            guard let mediaId = credit.id else { return nil }
            let kind: MediaKind = credit.mediaType == "tv" ? .tv : .movie
            let title = credit.title ?? credit.name ?? ""
            guard !title.isEmpty else { return nil }
            let date = credit.releaseDate ?? credit.firstAirDate ?? ""
            return PersonCredit(
                id: mediaId,
                title: title,
                mediaKind: kind,
                character: credit.character,
                posterPath: credit.posterPath,
                releaseDate: date,
                voteAverage: credit.voteAverage ?? 0,
                voteCount: credit.voteCount ?? 0,
                episodeCount: credit.episodeCount
            )
        }

        return PersonDetail(
            profile: PersonProfile(
                id: bundle.id,
                name: bundle.name ?? "",
                biography: bundle.biography ?? "",
                birthday: bundle.birthday,
                deathday: bundle.deathday,
                placeOfBirth: bundle.placeOfBirth,
                profilePath: bundle.profilePath,
                knownForDepartment: bundle.knownForDepartment,
                homepage: bundle.homepage
            ),
            credits: credits,
            externalLinks: links
        )
    }
}

struct TMDBPersonBundleDTO: Decodable, Sendable {
    let id: Int
    let name: String?
    let biography: String?
    let birthday: String?
    let deathday: String?
    let placeOfBirth: String?
    let profilePath: String?
    let knownForDepartment: String?
    let homepage: String?
    let combinedCredits: TMDBCombinedCreditsDTO?
    let externalIds: TMDBPersonExternalIdsDTO?
}

struct TMDBCombinedCreditsDTO: Decodable, Sendable {
    let cast: [TMDBPersonCreditDTO]?
}

struct TMDBPersonCreditDTO: Decodable, Sendable {
    let id: Int?
    let title: String?
    let name: String?
    let character: String?
    let mediaType: String?
    let posterPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let voteCount: Int?
    let episodeCount: Int?
}

struct TMDBPersonExternalIdsDTO: Decodable, Sendable {
    let imdbId: String?
    let instagramId: String?
    let twitterId: String?
    let facebookId: String?
}
