import XCTest
@testable import CoreStreaming
@testable import CoreTorrent

final class PieceStoreTests: XCTestCase {
    func testWriteAndReadPiece() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_piece_store")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let store = try await PieceStore(
            infoHash: "test123",
            pieceCount: 4,
            pieceSize: 1024,
            storageDirectory: tempDir
        )

        let testData = Data(repeating: 0xAB, count: 1024)
        try await store.write(pieceIndex: 0, data: testData)

        let hasPiece = await store.hasPiece(0)
        let hasPiece2 = await store.hasPiece(1)
        XCTAssertTrue(hasPiece)
        XCTAssertFalse(hasPiece2)

        let readData = try await store.read(offset: 0, length: 1024)
        XCTAssertEqual(readData, testData)

        await store.cleanup()
        try FileManager.default.removeItem(at: tempDir)
    }

    func testProgressCalculation() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_progress")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let store = try await PieceStore(
            infoHash: "progress_test",
            pieceCount: 4,
            pieceSize: 1024,
            storageDirectory: tempDir
        )

        var progress = await store.progress()
        XCTAssertEqual(progress, 0.0)

        let testData = Data(repeating: 0, count: 1024)
        try await store.write(pieceIndex: 0, data: testData)
        progress = await store.progress()
        XCTAssertEqual(progress, 0.25)

        try await store.write(pieceIndex: 1, data: testData)
        try await store.write(pieceIndex: 2, data: testData)
        try await store.write(pieceIndex: 3, data: testData)
        progress = await store.progress()
        XCTAssertEqual(progress, 1.0)

        await store.cleanup()
        try FileManager.default.removeItem(at: tempDir)
    }

    func testInvalidPieceIndex() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_invalid")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let store = try await PieceStore(
            infoHash: "invalid_test",
            pieceCount: 2,
            pieceSize: 1024,
            storageDirectory: tempDir
        )

        do {
            try await store.write(pieceIndex: -1, data: Data())
            XCTFail("Should have thrown invalidPieceIndex")
        } catch PieceStoreError.invalidPieceIndex(let index) {
            XCTAssertEqual(index, -1)
        }

        await store.cleanup()
        try FileManager.default.removeItem(at: tempDir)
    }
}

final class ReleaseParserIntegrationTests: XCTestCase {
    func testParseQualityFromTorrentTitle() {
        XCTAssertEqual(ReleaseParser.parseQuality(from: "Movie.2024.2160p.WEB-DL.x265"), .p2160)
        XCTAssertEqual(ReleaseParser.parseQuality(from: "Movie.2024.1080p.BluRay.x264"), .p1080)
        XCTAssertEqual(ReleaseParser.parseQuality(from: "Movie.2024.720p.WEBRip.x264"), .p720)
    }

    func testParseHDRFromTorrentTitle() {
        XCTAssertNotNil(ReleaseParser.parseHDR(from: "Movie.2024.2160p.HDR10.WEB-DL"))
        XCTAssertEqual(ReleaseParser.parseHDR(from: "Movie.2024.2160p.HDR10.WEB-DL"), .hdr10)
        XCTAssertNil(ReleaseParser.parseHDR(from: "Movie.2024.1080p.WEB-DL"))
    }

    func testParseCodecFromTorrentTitle() {
        XCTAssertEqual(ReleaseParser.parseCodec(from: "Movie.2024.1080p.x265.WEB-DL"), .h265)
        XCTAssertEqual(ReleaseParser.parseCodec(from: "Movie.2024.1080p.x264.WEB-DL"), .h264)
        XCTAssertEqual(ReleaseParser.parseCodec(from: "Movie.2024.2160p.AV1.WEB-DL"), .av1)
    }
}

final class StreamingEndToEndTests: XCTestCase {
    func testMetadataFetchAndP2P() async throws {
        let bbbHash = "0e876ce2a1a504f849ca72a5e2bc07347b3bc957"
        
        print("--- STARTING METADATA FETCH TEST FOR BIG BUCK BUNNY ---")
        do {
            let metadata = try await TorrentMetadataFetcher.fetch(infoHash: bbbHash, magnetTrackers: [])
            print("Successfully resolved metadata:")
            print("Name: \(metadata.name)")
            print("Piece Count: \(metadata.pieceCount)")
            print("Total Size: \(metadata.totalSize)")
            XCTAssertFalse(metadata.name.isEmpty)
        } catch {
            print("Failed to fetch metadata: \(error)")
            XCTFail("Metadata fetch failed: \(error)")
        }
    }
}
