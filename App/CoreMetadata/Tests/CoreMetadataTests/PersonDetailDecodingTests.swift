@testable import CoreMetadata
import Foundation
import Testing

@Test func decodesPersonWithStringSocialIds() throws {
    let json = """
    {
      "id": 819,
      "name": "Edward Norton",
      "biography": "Actor",
      "combined_credits": {
        "cast": [{
          "id": 550,
          "title": "Fight Club",
          "media_type": "movie",
          "character": "The Narrator",
          "poster_path": "/p.jpg",
          "release_date": "1999-10-15",
          "vote_average": 8.4,
          "vote_count": 100
        }]
      },
      "external_ids": {
        "imdb_id": "nm0001570",
        "facebook_id": "officialedwardnorton",
        "instagram_id": "edwardnortonofficial",
        "twitter_id": "EdwardNorton"
      }
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let bundle = try decoder.decode(TMDBPersonBundleDTO.self, from: json)
    let detail = PersonDetailMapper.map(bundle: bundle)

    #expect(detail.profile.name == "Edward Norton")
    #expect(detail.externalLinks.instagramId == "edwardnortonofficial")
    #expect(detail.credits.count == 1)
}
