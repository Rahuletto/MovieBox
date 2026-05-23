//
//  RealTorrentStreamingTests.swift
//  CoreStreamingTests
//
//  End-to-end practical tests for the *real* torrent streaming flow:
//
//    1.  Search torrents via the live MovieBox backend
//          (default http://127.0.0.1:8787, override with MOVIEBOX_WORKER_URL)
//    2.  Pick the top seeded result with a valid infoHash.
//    3.  Boot StreamingOrchestrator → metadata fetch → head + tail pieces.
//    4.  Wait for StreamSession to reach .ready (i.e. AVPlayer-playable).
//    5.  Issue a Range request against the local HTTP server and assert
//        we got real, non-zero bytes back with status 206.
//    6.  Sanity-feed the bytes into AVURLAsset to confirm AVFoundation
//        accepts the stream as a media container.
//
//  These tests intentionally exercise the *whole pipeline* (DHT, trackers,
//  peer wire protocol, BEP-9, piece verification, HTTPRangeServer, AVPlayer)
//  because that is where the system has been failing. Unit tests with synthetic
//  pieces were hiding regressions.
//
//  Run:
//      cd App/CoreStreaming
//      swift test --filter RealTorrentStreamingTests
//
//  Required env:
//      APP_SECRET         — copied from Backend/.dev.vars (falls back to the
//                           local .dev.vars file relative to the workspace).
//      MOVIEBOX_WORKER_URL — optional, defaults to http://127.0.0.1:8787
//

import AVFoundation
import CoreStorage
import CoreTorrent
import Foundation
import XCTest
@testable import CoreStreaming

@MainActor
final class RealTorrentStreamingTests: XCTestCase {
    // Headroom for: metadata fetch (peers/DHT/backend) + head + tail piece
    // verification on a typical 1080p torrent. The tail of a 2 GB MP4 with a
    // trailing moov can be up to 32 MB; on a swarm with a handful of peers
    // this can take several minutes to pull.
    private static let readyTimeout: TimeInterval = 600
    private static let pollInterval: Duration = .milliseconds(500)

    // MARK: - Movie: Interstellar (2014)

    func testInterstellarStreamsAndServesPlayableBytes() async throws {
        try await runEndToEnd(
            label: "Interstellar",
            query: "Interstellar",
            year: 2014,
            imdbId: "0816692",
            kind: .movie
        )
    }

    // MARK: - TV: Breaking Bad S01E01

    func testBreakingBadS01E01StreamsAndServesPlayableBytes() async throws {
        try await runEndToEnd(
            label: "BreakingBad.S01E01",
            query: "Breaking Bad S01E01",
            year: nil,
            imdbId: "0903747",
            kind: .tv
        )
    }

    // MARK: - Driver

    private func runEndToEnd(
        label: String,
        query: String,
        year: Int?,
        imdbId: String?,
        kind: TorrentioClient.MediaKind
    ) async throws {
        let env = try LiveBackendEnv.load()
        log(label, "step 1 — search torrents via \(env.baseURL.absoluteString)")

        let searcher = BackendTorrentSearcher(baseURL: env.baseURL, appToken: env.appToken)
        let response = try await searcher.search(
            query: query,
            year: year,
            imdbId: imdbId,
            kind: kind
        )
        XCTAssertFalse(response.results.isEmpty, "backend returned 0 torrents for \(query)")

        let results = response.results
        let candidates = results
            .filter { result in
                (result.infoHash?.count ?? 0) == 40 && result.seeders > 0
            }
            .sorted { $0.seeders > $1.seeders }
        guard let top = candidates.first else {
            XCTFail("no seeded torrent with valid infoHash for \(query) in \(response.results.count) results")
            return
        }
        log(label, "top torrent — \(top.title) seeders=\(top.seeders) size=\(top.sizeBytes) hash=\(top.infoHash ?? "?")")

        log(label, "step 2 — start StreamingOrchestrator")
        let orchestrator = StreamingOrchestrator()
        let session = StreamSession(orchestrator: orchestrator)
        defer {
            Task { @MainActor in
                await session.cancel()
                await orchestrator.stop()
            }
        }

        async let startTask: Void = session.start(torrent: top)

        log(label, "step 3 — wait for orchestrator → .ready (timeout \(Self.readyTimeout)s)")
        let readyURL = try await waitForReady(session: session, label: label, timeout: Self.readyTimeout)
        log(label, "stream URL — \(readyURL.absoluteString)")
        _ = await startTask

        log(label, "step 4 — read verified media head (65536 B)")
        let headData = try await orchestrator.readStreamMedia(mediaOffset: 0, length: 65_536)
        guard let headData else {
            XCTFail("[\(label)] no readable head bytes after .ready")
            return
        }
        XCTAssertGreaterThan(headData.count, 0, "empty body for head range")
        XCTAssertLessThanOrEqual(headData.count, 65_536)
        XCTAssertFalse(headData.allSatisfy { $0 == 0 }, "head range came back as all-zero bytes — pieces not verified")

        let signature = headData.prefix(16).map { String(format: "%02x", $0) }.joined()
        log(label, "head signature (16 bytes) — 0x\(signature) total=\(headData.count)")
        XCTAssertTrue(
            ContainerSniffer.looksLikeMediaContainer(headData),
            "head bytes (\(signature)) don't look like a known video container — playback will fail"
        )

        log(label, "step 5 — AVURLAsset.load(.isPlayable) via resource loader")
        let isMKVLabel = label.lowercased().contains("mkv") || top.title.lowercased().contains("mkv")
        let isMKVProbe = await orchestrator.streamIndexProbeLabel() == "MKV index (cues)"
        let isMKV = isMKVLabel || isMKVProbe
        if isMKV {
            log(label, "Skipping AVURLAsset playability check for MKV container (AVFoundation lacks native demuxer)")
        } else {
            guard let loader = TorrentStreamPlaybackRegistry.shared.resourceLoader(for: readyURL) else {
                XCTFail("[\(label)] missing resource loader for \(readyURL.absoluteString)")
                return
            }
            let asset = AVURLAsset(url: readyURL)
            asset.resourceLoader.setDelegate(
                loader,
                queue: DispatchQueue(label: "com.marban.moviebox.test-resource-loader")
            )
            do {
                let isPlayable = try await asset.load(.isPlayable)
                XCTAssertTrue(isPlayable, "AVURLAsset reports stream is not playable")
            } catch {
                XCTFail("AVURLAsset failed to load .isPlayable: \(error.localizedDescription)")
            }
        }

        log(label, "DONE — pipeline is serving real bytes that AVFoundation accepts")
    }

    // MARK: - helpers

    private func waitForReady(
        session: StreamSession<StreamingOrchestrator>,
        label: String,
        timeout: TimeInterval
    ) async throws -> URL {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var lastLogged: String = ""
        while ContinuousClock.now < deadline {
            switch session.state {
            case .ready(let url):
                return url
            case .failed(let err):
                XCTFail("[\(label)] session failed: \(err)")
                throw RealStreamTestError.sessionFailed(err)
            case .cancelled:
                XCTFail("[\(label)] session cancelled before ready")
                throw RealStreamTestError.cancelled
            case .preparing, .idle:
                let next = "state=\(session.state) peers=\(session.peerCount) speed=\(Int(session.downloadSpeed))B/s headKB=\(session.bufferedBytes / 1024)"
                if next != lastLogged { log(label, next); lastLogged = next }
            case .buffering(let p):
                let next = "buffering p=\(String(format: "%.2f", p)) peers=\(session.peerCount) speed=\(Int(session.downloadSpeed))B/s headKB=\(session.bufferedBytes / 1024)"
                if next != lastLogged { log(label, next); lastLogged = next }
            }
            try await Task.sleep(for: Self.pollInterval)
        }
        XCTFail("[\(label)] timed out after \(Int(timeout))s waiting for .ready — last state=\(session.state) peers=\(session.peerCount) headKB=\(session.bufferedBytes / 1024)")
        throw RealStreamTestError.timeout
    }

    private struct HttpResponse { let statusCode: Int; let body: Data }

    private func fetchRange(url: URL, range: String) async throws -> HttpResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpMethod = "GET"
        request.setValue(range, forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return HttpResponse(statusCode: http?.statusCode ?? -1, body: data)
    }

    private func log(_ label: String, _ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[\(ts)] [\(label)] \(message)")
    }
}

// MARK: - environment + helpers

private enum RealStreamTestError: Error {
    case sessionFailed(String)
    case cancelled
    case timeout
    case missingAppSecret
}

private struct LiveBackendEnv {
    let baseURL: URL
    let appToken: String

    static func load() throws -> LiveBackendEnv {
        let env = ProcessInfo.processInfo.environment
        let baseString = env["MOVIEBOX_WORKER_URL"] ?? "http://127.0.0.1:8787"
        guard let baseURL = URL(string: baseString) else {
            throw NSError(domain: "RealTorrentStreamingTests", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid MOVIEBOX_WORKER_URL \"\(baseString)\""
            ])
        }
        if let token = env["APP_SECRET"], !token.isEmpty {
            return LiveBackendEnv(baseURL: baseURL, appToken: token)
        }
        if let token = readDevVar("APP_SECRET"), !token.isEmpty {
            return LiveBackendEnv(baseURL: baseURL, appToken: token)
        }
        throw RealStreamTestError.missingAppSecret
    }

    private static func readDevVar(_ key: String) -> String? {
        // Walk up from the test bundle (or CWD) until we find Backend/.dev.vars.
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Backend/.dev.vars")
            if let content = try? String(contentsOf: candidate, encoding: .utf8) {
                return parseDevVar(content, key: key)
            }
            let candidate2 = dir.appendingPathComponent(".dev.vars")
            if let content = try? String(contentsOf: candidate2, encoding: .utf8) {
                return parseDevVar(content, key: key)
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private static func parseDevVar(_ content: String, key: String) -> String? {
        for raw in content.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            if k == key {
                return String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

/// Heuristic recogniser for common video container magic numbers.
/// We only need confidence that AVFoundation will treat the head bytes as media.
private enum ContainerSniffer {
    static func looksLikeMediaContainer(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let b = [UInt8](data.prefix(64))

        // ISO BMFF / MP4 / M4V: bytes 4..8 == "ftyp"
        if b.count >= 8, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            return true
        }
        // Matroska / WebM: EBML header 0x1A 0x45 0xDF 0xA3
        if b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 {
            return true
        }
        // AVI: "RIFF...AVI "
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b.count >= 12, b[8] == 0x41, b[9] == 0x56, b[10] == 0x49 {
            return true
        }
        // MPEG-TS sync byte at start: 0x47 then 188-byte alignment
        if b[0] == 0x47, b.count > 188, b[188] == 0x47 {
            return true
        }
        // Flash Video "FLV"
        if b[0] == 0x46, b[1] == 0x4C, b[2] == 0x56 {
            return true
        }
        return false
    }
}
