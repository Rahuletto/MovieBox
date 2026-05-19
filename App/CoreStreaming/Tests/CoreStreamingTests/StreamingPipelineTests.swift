import XCTest
@testable import CoreStreaming
@testable import CoreTorrent

// MARK: - Progressive disk + HTTP pipeline (no live peers)

final class ProgressiveStreamingTests: XCTestCase {
    private let blockSize = 16_384
    private let pieceSize: Int64 = 256 * 1024

    func testProgressiveBlockWriteAllowsReadBeforeVerify() async throws {
        let tempDir = makeTempDir("progressive_read")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try await PieceStore(
            infoHash: "progressive_read",
            pieceCount: 4,
            pieceSize: pieceSize,
            storageDirectory: tempDir
        )

        let initialHead = await store.streamHeadContiguousBytes()
        XCTAssertEqual(initialHead, 0)

        for blockIndex in 0..<12 {
            let offset = Int64(blockIndex * blockSize)
            let byte = UInt8(blockIndex)
            try await store.writeBlock(
                pieceIndex: 0,
                blockOffset: offset,
                data: Data(repeating: byte, count: blockSize)
            )
        }

        let head = await store.streamHeadContiguousBytes()
        XCTAssertEqual(head, Int64(12 * blockSize))

        let read = try await store.read(offset: 0, length: blockSize)
        XCTAssertEqual(read.first, 0)
        let pieceVerified = await store.hasPiece(0)
        XCTAssertFalse(pieceVerified)

        await store.cleanup()
    }

    func testPieceManagerRequestsPieceZeroBeforeOthers() async {
        let manager = PieceManager(
            pieceCount: 5,
            pieceLength: pieceSize,
            totalSize: pieceSize * 5,
            piecesHash: Data(repeating: 0, count: 5 * 20)
        )

        for _ in 0..<24 {
            guard let request = await manager.getNextRequest() else {
                XCTFail("Expected block requests for piece 0")
                return
            }
            XCTAssertEqual(request.pieceIndex, 0, "Must complete piece 0 before other pieces")
            await manager.recycleRequests([request])
        }
    }

    func testPlaybackReadinessThreshold() {
        XCTAssertEqual(StreamPlaybackThreshold.minimumHeadBytes, 192 * 1024)
    }
}

@MainActor
final class HTTPRangeServerTests: XCTestCase {
    func testRangeServerServesProgressiveBytes() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("http_range_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pieceSize: Int64 = 256 * 1024
        let fileLength: Int64 = pieceSize * 2
        let store = try await PieceStore(
            infoHash: "http_range_test",
            pieceCount: 2,
            pieceSize: pieceSize,
            totalSize: fileLength,
            storageDirectory: tempDir
        )

        let metadata = TorrentMetadata(
            infoHash: "http_range_test",
            name: "sample.mp4",
            totalSize: fileLength,
            pieceLength: pieceSize,
            pieces: Data(repeating: 0, count: 40),
            files: [TorrentFile(path: ["sample.mp4"], length: fileLength)],
            trackers: []
        )
        let target = TorrentStreamTarget.selectPrimary(from: metadata)

        let blockSize = 16_384
        let pattern = Data("MOVIEBOX-STREAM-TEST".utf8)
        for blockIndex in 0..<16 {
            var block = Data()
            while block.count < blockSize {
                block.append(pattern)
            }
            block = block.prefix(blockSize)
            try await store.writeBlock(
                pieceIndex: 0,
                blockOffset: Int64(blockIndex * blockSize),
                data: block
            )
        }

        let server = HTTPRangeServer()
        server.configureForTests(pieceStore: store, streamTarget: target)

        let request = "GET /stream HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-16383\r\n\r\n"
        let response = await server.handleRequest(request, pieceStore: store)

        XCTAssertEqual(response.status, 206)
        let headerEnd = response.data.range(of: Data("\r\n\r\n".utf8))!
        let body = response.data[headerEnd.upperBound...]
        XCTAssertEqual(body.count, 16_384)
        XCTAssertTrue(body.starts(with: pattern.prefix(16)))

        await store.cleanup()
    }

    func testOpenEndedRangeIsClampedNot416() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("http_range_open_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pieceSize: Int64 = 256 * 1024
        let fileLength: Int64 = pieceSize * 40
        let store = try await PieceStore(
            infoHash: "http_range_open_test",
            pieceCount: 40,
            pieceSize: pieceSize,
            totalSize: fileLength,
            storageDirectory: tempDir
        )

        let metadata = TorrentMetadata(
            infoHash: "http_range_open_test",
            name: "large.mkv",
            totalSize: fileLength,
            pieceLength: pieceSize,
            pieces: Data(repeating: 0, count: 800),
            files: [TorrentFile(path: ["large.mkv"], length: fileLength)],
            trackers: []
        )
        let target = TorrentStreamTarget.selectPrimary(from: metadata)

        let blockSize = 16_384
        let pattern = Data("MOVIEBOX-OPEN-RANGE".utf8)
        for blockIndex in 0..<16 {
            var block = Data()
            while block.count < blockSize {
                block.append(pattern)
            }
            block = block.prefix(blockSize)
            try await store.writeBlock(
                pieceIndex: 0,
                blockOffset: Int64(blockIndex * blockSize),
                data: block
            )
        }

        let server = HTTPRangeServer()
        server.configureForTests(pieceStore: store, streamTarget: target)

        let request = "GET /stream HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-\r\n\r\n"
        let response = await server.handleRequest(request, pieceStore: store)

        XCTAssertEqual(response.status, 206)
        let headerEnd = response.data.range(of: Data("\r\n\r\n".utf8))!
        let body = response.data[headerEnd.upperBound...]
        XCTAssertEqual(body.count, 2 * 1024 * 1024)

        await store.cleanup()
    }
}

final class TorrentStreamTargetTests: XCTestCase {
    func testSelectsLargestVideoFileInMultiFileTorrent() {
        let metadata = TorrentMetadata(
            infoHash: "multi",
            name: "release",
            totalSize: 6_000_000,
            pieceLength: 1_048_576,
            pieces: Data(repeating: 0, count: 200),
            files: [
                TorrentFile(path: ["Sample", "Subs", "subs.srt"], length: 50_000),
                TorrentFile(path: ["Sample", "Sample.mkv"], length: 5_000_000),
                TorrentFile(path: ["Sample", "readme.txt"], length: 1_000),
            ],
            trackers: []
        )

        let target = TorrentStreamTarget.selectPrimary(from: metadata)
        XCTAssertTrue(target.file.relativePath.hasSuffix("Sample.mkv"))
        XCTAssertEqual(target.byteOffset, 50_000)
        XCTAssertEqual(target.byteLength, 5_000_000)
        XCTAssertEqual(target.contentType, "video/x-matroska")
    }
}

private extension ProgressiveStreamingTests {
    func makeTempDir(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
