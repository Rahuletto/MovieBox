import CryptoKit
import XCTest
@testable import CoreStreaming
@testable import CoreTorrent

// MARK: - Mock orchestrator for StreamSession

@MainActor
final class MockStreamingOrchestrator: StreamingOrchestration, @unchecked Sendable {
    var streamURL = URL(string: "http://127.0.0.1:9999/stream")!
    var headBytes: Int64 = 0
    var verifiedPieces = 0
    var overallProgress: Double = 0
    var speed: Double = 0
    var peers: Int = 0
    var startCallCount = 0
    var stopCallCount = 0

    private var progressHandler: (@Sendable (Double, Double, Int) -> Void)?

    func startStream(
        torrent: TorrentResult,
        progressHandler: @escaping @Sendable (Double, Double, Int) -> Void
    ) async throws -> URL {
        startCallCount += 1
        self.progressHandler = progressHandler
        progressHandler(overallProgress, speed, peers)
        return streamURL
    }

    func stop() async {
        stopCallCount += 1
    }

    func progress() async -> Double { overallProgress }
    func contiguousPiecesFromStart() async -> Int { verifiedPieces }
    func contiguousBytesFromStreamStart() async -> Int64 {
        guard verifiedPieces > 0 else { return 0 }
        return headBytes
    }

    func streamHeadContiguousBytes() async -> Int64 { headBytes }
    func downloadSpeed() async -> Double { speed }
    func peerCount() async -> Int { peers }

    func emitProgress() {
        progressHandler?(overallProgress, speed, peers)
    }
}

// MARK: - Local pipeline harness (no network peers)

@MainActor
final class LocalStreamingHarness {
    let metadata: TorrentMetadata
    let target: TorrentStreamTarget
    let store: PieceStore
    let manager: PieceManager
    let server = HTTPRangeServer()

    init(metadata: TorrentMetadata) async throws {
        self.metadata = metadata
        self.target = TorrentStreamTarget.selectPrimary(from: metadata)
        store = try await PieceStore(
            infoHash: metadata.infoHash,
            pieceCount: metadata.pieceCount,
            pieceSize: metadata.pieceLength,
            totalSize: metadata.totalSize,
            streamFirstPiece: target.firstPieceIndex,
            streamMediaByteOffset: target.byteOffset,
            storageDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("moviebox_test_\(UUID().uuidString)")
        )
        manager = PieceManager(
            pieceCount: metadata.pieceCount,
            pieceLength: metadata.pieceLength,
            totalSize: metadata.totalSize,
            piecesHash: metadata.pieces,
            streamFirstPiece: target.firstPieceIndex
        )
    }

    func startHTTPServer() async throws -> URL {
        try await server.start(pieceStore: store, streamTarget: target)
    }

    func ingestBlock(pieceIndex: UInt32, offset: UInt32, block: Data) async -> Bool {
        await PieceIngestion.apply(
            pieceStore: store,
            pieceManager: manager,
            pieceIndex: pieceIndex,
            offset: offset,
            block: block
        )
    }

    func fillHeadBytes(_ byteCount: Int, startingPiece: UInt32 = 0) async throws {
        let blockSize = 16_384
        var written = 0
        var piece = startingPiece
        var offset: UInt32 = 0

        while written < byteCount {
            let length = min(blockSize, byteCount - written)
            let block = Data(repeating: UInt8(written % 251), count: length)
            _ = await ingestBlock(pieceIndex: piece, offset: offset, block: block)
            written += length
            offset += UInt32(length)
            if Int64(offset) >= metadata.pieceLength {
                piece += 1
                offset = 0
            }
        }
    }

    func cleanup() async {
        await server.stop()
        await store.cleanup()
    }
}

// MARK: - Integration tests

@MainActor
final class StreamSessionIntegrationTests: XCTestCase {
    func testBecomesReadyAt192KBHead() async throws {
        let mock = MockStreamingOrchestrator()
        mock.streamURL = URL(string: "http://127.0.0.1:8080/stream")!
        mock.headBytes = StreamPlaybackThreshold.minimumHeadBytes
        mock.peers = 3

        let session = StreamSession(orchestrator: mock)
        let torrent = makeTestTorrent()

        await session.start(torrent: torrent)

        guard case .ready(let url) = session.state else {
            XCTFail("Expected ready, got \(session.state)")
            return
        }
        XCTAssertEqual(url, mock.streamURL)
        XCTAssertGreaterThanOrEqual(session.bufferedBytes, StreamPlaybackThreshold.minimumHeadBytes)
    }

    func testStaysBufferingBelowThreshold() async throws {
        let mock = MockStreamingOrchestrator()
        mock.streamURL = URL(string: "http://127.0.0.1:8081/stream")!
        mock.headBytes = StreamPlaybackThreshold.minimumHeadBytes / 2

        let session = StreamSession(orchestrator: mock)
        let torrent = makeTestTorrent(seeders: 1)

        await session.start(torrent: torrent)

        if case .buffering = session.state {
            // expected
        } else {
            XCTFail("Expected buffering, got \(session.state)")
        }
    }

    func testBecomesReadyWithOneVerifiedPiece() async throws {
        let mock = MockStreamingOrchestrator()
        mock.streamURL = URL(string: "http://127.0.0.1:8082/stream")!
        mock.verifiedPieces = 1
        mock.headBytes = 1024

        let session = StreamSession(orchestrator: mock)
        let torrent = makeTestTorrent(seeders: 5, quality: .p1080, codec: .h265, source: .bluray)

        await session.start(torrent: torrent)

        if case .ready = session.state {
            // expected
        } else {
            XCTFail("Expected ready with verified piece, got \(session.state)")
        }
    }
}

@MainActor
final class FullPipelineIntegrationTests: XCTestCase {
    func testLiveHTTPServerURLSessionRange() async throws {
        let pieceSize: Int64 = 512 * 1024
        let fileLength = pieceSize
        let metadata = TorrentMetadata(
            infoHash: "live_http_test",
            name: "clip.mp4",
            totalSize: fileLength,
            pieceLength: pieceSize,
            pieces: Data(repeating: 0xAB, count: 20),
            files: [TorrentFile(path: ["clip.mp4"], length: fileLength)],
            trackers: []
        )

        let harness = try await LocalStreamingHarness(metadata: metadata)
        defer { Task { await harness.cleanup() } }

        try await harness.fillHeadBytes(Int(StreamPlaybackThreshold.minimumHeadBytes))
        let url = try await harness.startHTTPServer()

        try await Task.sleep(for: .milliseconds(700))

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(data.count, 4096)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertNotNil(http.value(forHTTPHeaderField: "Content-Range"))

        await harness.cleanup()
    }

    func testMultiFileStreamReadsAtVideoOffset() async throws {
        let pieceLength: Int64 = 256 * 1024
        let subsLength: Int64 = 50_000
        let videoLength: Int64 = pieceLength * 2
        let totalSize = subsLength + videoLength + 1_000

        let metadata = TorrentMetadata(
            infoHash: "multi_http",
            name: "release",
            totalSize: totalSize,
            pieceLength: pieceLength,
            pieces: Data(repeating: 0xCD, count: 300),
            files: [
                TorrentFile(path: ["Subs", "subs.srt"], length: subsLength),
                TorrentFile(path: ["Video", "main.mkv"], length: videoLength),
                TorrentFile(path: ["readme.txt"], length: 1_000),
            ],
            trackers: []
        )

        let harness = try await LocalStreamingHarness(metadata: metadata)
        defer { Task { await harness.cleanup() } }

        XCTAssertEqual(harness.target.byteOffset, subsLength)
        XCTAssertEqual(harness.target.firstPieceIndex, 0)

        let marker = Data(repeating: 0x42, count: 16_384)
        _ = await harness.ingestBlock(
            pieceIndex: 0,
            offset: UInt32(subsLength),
            block: marker
        )

        let url = try await harness.startHTTPServer()
        try await Task.sleep(for: .milliseconds(700))

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("bytes=0-16383", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(data, marker)

        await harness.cleanup()
    }

    func testPieceVerificationWithValidHash() async throws {
        let pieceLength: Int64 = 32 * 1024
        let pieceData = Data((0..<Int(pieceLength)).map { UInt8($0 % 256) })
        let hash = Data(Insecure.SHA1.hash(data: pieceData))

        var piecesBlob = Data()
        piecesBlob.append(hash)
        piecesBlob.append(Data(repeating: 0, count: 19))

        let metadata = TorrentMetadata(
            infoHash: "hash_verify",
            name: "one.bin",
            totalSize: pieceLength,
            pieceLength: pieceLength,
            pieces: piecesBlob,
            files: [TorrentFile(path: ["one.bin"], length: pieceLength)],
            trackers: []
        )

        let harness = try await LocalStreamingHarness(metadata: metadata)
        defer { Task { await harness.cleanup() } }

        let blockSize = 16_384
        for blockIndex in 0..<2 {
            let start = blockIndex * blockSize
            let block = pieceData.subdata(in: start..<(start + blockSize))
            let complete = await harness.ingestBlock(
                pieceIndex: 0,
                offset: UInt32(start),
                block: block
            )
            if blockIndex == 1 {
                XCTAssertTrue(complete)
            } else {
                XCTAssertFalse(complete)
            }
        }

        let hasPiece = await harness.store.hasPiece(0)
        let downloaded = await harness.manager.downloadedCount()
        XCTAssertTrue(hasPiece)
        XCTAssertEqual(downloaded, 1)
    }

    func testMultiFileHeadContiguousTracksFromFileStart() async throws {
        let pieceLength: Int64 = 256 * 1024
        let subsLength: Int64 = 50_000
        let videoLength: Int64 = pieceLength
        let totalSize = subsLength + videoLength

        let metadata = TorrentMetadata(
            infoHash: "multi_head",
            name: "release",
            totalSize: totalSize,
            pieceLength: pieceLength,
            pieces: Data(repeating: 0xEE, count: 40),
            files: [
                TorrentFile(path: ["subs.srt"], length: subsLength),
                TorrentFile(path: ["movie.mkv"], length: videoLength),
            ],
            trackers: []
        )

        let harness = try await LocalStreamingHarness(metadata: metadata)
        _ = await harness.ingestBlock(pieceIndex: 0, offset: UInt32(subsLength), block: Data(repeating: 0x99, count: 16_384))

        let head = await harness.store.streamHeadContiguousBytes()
        XCTAssertEqual(head, 16_384)
        await harness.cleanup()
    }

    func testEndToEndIngestionReachesPlayThreshold() async throws {
        let pieceLength: Int64 = 256 * 1024
        let fileLength = pieceLength * 4
        let metadata = TorrentMetadata(
            infoHash: "e2e_threshold",
            name: "movie.mp4",
            totalSize: fileLength,
            pieceLength: pieceLength,
            pieces: Data(repeating: 0x01, count: 80),
            files: [TorrentFile(path: ["movie.mp4"], length: fileLength)],
            trackers: []
        )

        let harness = try await LocalStreamingHarness(metadata: metadata)
        defer { Task { await harness.cleanup() } }

        try await harness.fillHeadBytes(Int(StreamPlaybackThreshold.minimumHeadBytes) + 4096)

        let head = await harness.store.streamHeadContiguousBytes()
        XCTAssertGreaterThanOrEqual(head, StreamPlaybackThreshold.minimumHeadBytes)

        let url = try await harness.startHTTPServer()
        try await Task.sleep(for: .milliseconds(700))

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertLessThanOrEqual(data.count, 512 * 1024)

        await harness.cleanup()
    }
}

private func makeTestTorrent(
    seeders: Int = 10,
    quality: VideoQuality = .p720,
    codec: VideoCodec = .h264,
    source: VideoSource = .webdl
) -> TorrentResult {
    TorrentResult(
        title: "Test.Release.2024.1080p.WEB-DL.x264",
        magnetURI: "magnet:?xt=urn:btih:0e876ce2a1a504f849ca72a5e2bc07347b3bc957",
        quality: quality,
        hdrType: nil,
        codec: codec,
        audioFormat: nil,
        source: source,
        sizeBytes: 1_000_000,
        seeders: seeders,
        leechers: 1,
        trackerSource: .torrentio,
        infoHash: "0e876ce2a1a504f849ca72a5e2bc07347b3bc957",
        language: "en"
    )
}
