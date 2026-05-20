import XCTest
@testable import CoreMetadata

final class ContentAdvisoryExtractorTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func testMovieReleaseDatesPrefersPreferredRegionAndSplitsCompoundDescriptors() throws {
        let json = """
        {
          "results": [
            {
              "iso_3166_1": "CA",
              "release_dates": [
                { "certification": "18A", "descriptors": ["Violence"], "type": 3 }
              ]
            },
            {
              "iso_3166_1": "TR",
              "release_dates": [
                { "certification": "", "descriptors": ["Sexuality", "Violence / Horror"], "type": 3 }
              ]
            }
          ]
        }
        """
        let payload = try decoder.decode(TMDBReleaseDatesAppendDTO.self, from: Data(json.utf8))
        let advisories = ContentAdvisoryExtractor.fromMovieReleaseDates(payload.results)
        XCTAssertEqual(advisories, ["Violence", "Sexual Content", "Horror"])
    }

    func testTVContentRatingsDedupesAcrossRegions() throws {
        let json = """
        {
          "results": [
            { "descriptors": ["Violence"], "iso_3166_1": "CA", "rating": "18+" },
            { "descriptors": ["violence"], "iso_3166_1": "GB", "rating": "15" }
          ]
        }
        """
        let payload = try decoder.decode(TMDBContentRatingsAppendDTO.self, from: Data(json.utf8))
        let advisories = ContentAdvisoryExtractor.fromTVContentRatings(payload.results)
        XCTAssertEqual(advisories, ["Violence"])
    }

    func testCategoryLabelsStripsContainsAndMapsKnownTerms() {
        XCTAssertEqual(
            ContentAdvisoryExtractor.categoryLabels(for: "Contains Nudity"),
            ["Nudity"]
        )
        XCTAssertEqual(
            ContentAdvisoryExtractor.categoryLabels(for: "Violence / Horror"),
            ["Violence", "Horror"]
        )
        XCTAssertEqual(
            ContentAdvisoryExtractor.normalizeCategory("may cause anxiety"),
            "Horror"
        )
    }
}
