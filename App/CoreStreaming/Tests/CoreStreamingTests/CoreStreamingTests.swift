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

    func testBlockingReadSuccess() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_blocking_read")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let store = try await PieceStore(
            infoHash: "blocking_test",
            pieceCount: 2,
            pieceSize: 1024,
            storageDirectory: tempDir
        )

        let testData = Data(repeating: 0x55, count: 1024)

        // Spin up a background task to write the piece after a short delay
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            try? await store.write(pieceIndex: 0, data: testData)
        }

        // Call read immediately (should block until the piece is written by the background task)
        let startTime = Date.now
        let readData = try await store.read(offset: 0, length: 1024)
        let elapsed = Date.now.timeIntervalSince(startTime)

        XCTAssertEqual(readData, testData)
        XCTAssertGreaterThanOrEqual(elapsed, 0.19) // Verify that it blocked for the write delay

        await store.cleanup()
        try FileManager.default.removeItem(at: tempDir)
    }

    func testBlockingReadCancellation() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_blocking_cancel")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let store = try await PieceStore(
            infoHash: "blocking_cancel_test",
            pieceCount: 2,
            pieceSize: 1024,
            storageDirectory: tempDir
        )

        // Spin up a task that reads and will block forever since we won't write
        let readTask = Task {
            _ = try await store.read(offset: 0, length: 1024)
        }

        try? await Task.sleep(for: .milliseconds(100))
        readTask.cancel()

        let result = await readTask.result
        switch result {
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        case .success:
            XCTFail("Should have been cancelled")
        }

        await store.cleanup()
        try FileManager.default.removeItem(at: tempDir)
    }

    func testWireMessageDecodeWithSliceOffset() {
        // Construct a wire message (unchoke message: length = 1, ID = 1)
        // [0, 0, 0, 1, 1]
        let originalBuffer = Data([0xAA, 0xBB, 0xCC, 0x00, 0x00, 0x00, 0x01, 0x01, 0xDD, 0xEE])
        
        // Slice the buffer from index 3 to 7 (inclusive of [0, 0, 0, 1, 1])
        let slice = originalBuffer[3...7]
        XCTAssertEqual(slice.startIndex, 3)
        
        // Decode the slice
        let decoded = WireMessage.decode(slice)
        XCTAssertEqual(decoded, .unchoke)
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
