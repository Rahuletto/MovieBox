import XCTest
import SwiftData
@testable import CoreStorage

final class DownloadRecordTests: XCTestCase {
    func testDownloadRecordRoundTrip() throws {
        let schema = Schema([DownloadRecord.self, MovieRecord.self, AppSettings.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)

        let record = DownloadRecord(
            infoHash: "abc123",
            tmdbId: 42,
            mediaKind: "tv",
            title: "Test Show",
            magnetURI: "magnet:?xt=urn:btih:abc123",
            quality: "1080p",
            storageDirectory: "/tmp/moviebox",
            state: .downloading,
            progressFraction: 0.5,
            totalBytes: 1000,
            downloadedBytes: 500,
            pieceBitmap: Data([0xFF])
        )
        context.insert(record)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<DownloadRecord>()).first
        XCTAssertEqual(fetched?.mediaKind, "tv")
        XCTAssertEqual(fetched?.storageDirectory, "/tmp/moviebox")
        XCTAssertEqual(fetched?.pieceBitmap, Data([0xFF]))
    }
}
