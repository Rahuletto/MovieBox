import Foundation
import XCTest
@testable import CoreStreaming

final class RemuxServiceTests: XCTestCase {
    func testHEVCMain10EAC3IsAccepted() throws {
        let plan = try makePlan(videoCodec: "hevc", videoProfile: "Main 10", audioCodecs: [("truehd", true), ("eac3", false)])

        XCTAssertEqual(plan.decision, .fmp4HLS)
        XCTAssertEqual(plan.videoTag, "hvc1")
        XCTAssertEqual(plan.audioStream?.codecName, "eac3")
    }

    func testH264EAC3UsesTSHLS() throws {
        let plan = try makePlan(videoCodec: "h264", audioCodecs: [("eac3", true)])

        XCTAssertEqual(plan.decision, .tsHLS)
        XCTAssertNil(plan.videoTag)
        XCTAssertEqual(plan.audioStream?.codecName, "eac3")
    }

    func testH264AACIsAcceptedWithoutHEVCTag() throws {
        let plan = try makePlan(videoCodec: "h264", audioCodecs: [("aac", true)])

        XCTAssertEqual(plan.decision, .tsHLS)
        XCTAssertNil(plan.videoTag)
        XCTAssertEqual(plan.audioStream?.codecName, "aac")
    }

    func testHEVCTrueHDIsRejected() throws {
        let plan = try makePlan(videoCodec: "hevc", audioCodecs: [("truehd", true)])

        XCTAssertEqual(plan.decision, .unsupported)
        XCTAssertEqual(plan.unsupportedReason, "Audio codec truehd is not AVPlayer-compatible in strict preservation mode.")
    }

    func testHEVCDTSIsRejected() throws {
        let plan = try makePlan(videoCodec: "hevc", audioCodecs: [("dts", true)])

        XCTAssertEqual(plan.decision, .unsupported)
        XCTAssertEqual(plan.unsupportedReason, "Audio codec dts is not AVPlayer-compatible in strict preservation mode.")
    }

    func testAV1IsRejected() throws {
        let plan = try makePlan(videoCodec: "av1", audioCodecs: [("aac", true)])

        XCTAssertEqual(plan.decision, .unsupported)
        XCTAssertEqual(plan.unsupportedReason, "Video codec av1 cannot be remuxed losslessly for AVPlayer.")
    }

    func testNoCompatibleAudioIsRejected() throws {
        let plan = try makePlan(videoCodec: "h264", audioCodecs: [("opus", true), ("flac", false)])

        XCTAssertEqual(plan.decision, .unsupported)
        XCTAssertEqual(plan.unsupportedReason, "Audio codec opus is not AVPlayer-compatible in strict preservation mode.")
    }

    func testAudioWithNumericBitsPerSampleDecodes() throws {
        let probe = try decode("""
        {
          "streams": [
            {
              "index": 0,
              "codec_type": "video",
              "codec_name": "hevc",
              "profile": "Main 10"
            },
            {
              "index": 1,
              "codec_type": "audio",
              "codec_name": "eac3",
              "bits_per_sample": 0,
              "disposition": { "default": 1 }
            }
          ],
          "format": { "format_name": "matroska,webm", "duration": 60.0 }
        }
        """)

        XCTAssertEqual(probe.audioStreams.first?.codecName, "eac3")
    }

    func testDolbyVisionSideDataIsDetected() throws {
        let probe = try decode("""
        {
          "streams": [
            {
              "index": 0,
              "codec_type": "video",
              "codec_name": "hevc",
              "profile": "Main 10",
              "color_transfer": "smpte2084",
              "side_data_list": [
                { "side_data_type": "DOVI configuration record", "dv_profile": 8 }
              ]
            },
            {
              "index": 1,
              "codec_type": "audio",
              "codec_name": "eac3",
              "disposition": { "default": 1 }
            }
          ],
          "format": { "format_name": "matroska,webm", "duration": "60.0" }
        }
        """)

        XCTAssertEqual(probe.videoStreams.first?.dynamicRange, .dolbyVision)
        XCTAssertEqual(probe.videoStreams.first?.hasDolbyVision, true)
    }

    func testHEVCCommandUsesFMP4HLSAndHVC1() throws {
        let plan = try makePlan(videoCodec: "hevc", audioCodecs: [("eac3", true)])
        let arguments = try RemuxService.buildFFmpegArguments(plan: plan)

        XCTAssertTrue(arguments.containsSubsequence(["-tag:v", "hvc1"]))
        XCTAssertTrue(arguments.containsSubsequence(["-tag:a", "ec-3"]))
        XCTAssertTrue(arguments.containsSubsequence(["-i", "/tmp/movie.mkv", "-map_chapters", "-1"]))
        XCTAssertTrue(arguments.containsSubsequence(["-f", "hls"]))
        XCTAssertTrue(arguments.containsSubsequence(["-hls_segment_type", "fmp4"]))
        XCTAssertTrue(arguments.containsSubsequence(["-hls_playlist_type", "vod"]))
        XCTAssertTrue(arguments.containsSubsequence(["-hls_fmp4_init_filename", "init.mp4"]))
        XCTAssertFalse(arguments.contains("delete_segments"))
        XCTAssertFalse(arguments.containsSubsequence(["-c:a", "aac"]))
    }

    func testH264EAC3CommandUsesTSHLS() throws {
        let plan = try makePlan(videoCodec: "h264", audioCodecs: [("eac3", true)])
        let arguments = try RemuxService.buildFFmpegArguments(plan: plan)

        XCTAssertTrue(arguments.containsSubsequence(["-tag:a", "ec-3"]))
        XCTAssertTrue(arguments.containsSubsequence(["-hls_segment_filename", "segment_%05d.ts"]))
        XCTAssertFalse(arguments.containsSubsequence(["-hls_segment_type", "fmp4"]))
        XCTAssertFalse(arguments.contains("hvc1"))
    }

    func testStreamingCommandUsesAppendList() throws {
        let plan = try makePlan(videoCodec: "hevc", audioCodecs: [("eac3", true)])
        let arguments = try RemuxService.buildStreamingFFmpegArguments(plan: plan)

        XCTAssertTrue(arguments.containsSubsequence(["-i", plan.inputURL.absoluteString, "-map_chapters", "-1"]))
        XCTAssertFalse(arguments.containsSubsequence(["-map_chapters", "-1", "-i"]))
        XCTAssertTrue(arguments.containsSubsequence(["-hls_playlist_type", "event"]))
        XCTAssertTrue(arguments.containsSubsequence(["-hls_flags", "append_list+independent_segments"]))
        XCTAssertTrue(arguments.containsSubsequence(["-reset_timestamps", "1"]))
        XCTAssertTrue(arguments.containsSubsequence(["-hls_list_size", "0"]))
        XCTAssertTrue(arguments.containsSubsequence(["-c", "copy"]))
        XCTAssertTrue(arguments.containsSubsequence(["-tag:a", "ec-3"]))
        XCTAssertFalse(arguments.containsSubsequence(["-c:a", "aac"]))
    }

    func testStreamingCommandKeepsCopyForAAC() throws {
        let plan = try makePlan(videoCodec: "h264", audioCodecs: [("aac", true)])
        let arguments = try RemuxService.buildStreamingFFmpegArguments(plan: plan)

        XCTAssertTrue(arguments.containsSubsequence(["-c", "copy"]))
        XCTAssertFalse(arguments.containsSubsequence(["-c:a", "aac"]))
        XCTAssertTrue(arguments.containsSubsequence(["-hls_segment_filename", "segment_%05d.ts"]))
    }

    func testNormalizeStreamingPlaylistRemovesLeadingDiscontinuity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlistURL = directory.appendingPathComponent("stream.m3u8")
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MAP:URI="init.mp4"
        #EXT-X-DISCONTINUITY
        #EXTINF:4.0,
        segment_00000.m4s
        """
        try playlist.write(to: playlistURL, atomically: true, encoding: .utf8)
        RemuxService.normalizeStreamingPlaylist(at: playlistURL)
        let normalized = try String(contentsOf: playlistURL, encoding: .utf8)
        XCTAssertFalse(normalized.contains("#EXT-X-DISCONTINUITY"))
        XCTAssertTrue(normalized.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
    }

    func testStreamingPlayableRequiresThreeSegments() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4.0,
        segment_00000.m4s
        """
        try playlist.write(to: directory.appendingPathComponent("stream.m3u8"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: directory.appendingPathComponent("init.mp4"))
        try Data([0]).write(to: directory.appendingPathComponent("segment_00000.m4s"))

        XCTAssertTrue(RemuxService.hasPlayableHLS(in: directory))
        XCTAssertFalse(RemuxService.hasPlayableStreamingHLS(in: directory))
    }

    func testTSHLSPlaylistIsPlayable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXTINF:4.0,
        segment_00000.ts
        """
        try playlist.write(to: directory.appendingPathComponent("stream.m3u8"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: directory.appendingPathComponent("segment_00000.ts"))

        XCTAssertTrue(RemuxService.hasPlayableHLS(in: directory))
    }

    func testUnifiedMediaPlaylistIsPlayable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4.0,
        segment_00000.m4s
        """
        try playlist.write(to: directory.appendingPathComponent("stream.m3u8"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: directory.appendingPathComponent("init.mp4"))
        try Data([0]).write(to: directory.appendingPathComponent("segment_00000.m4s"))

        XCTAssertTrue(RemuxService.hasPlayableHLS(in: directory))
    }

    func testBrokenMasterPlaylistMissingChildIsNotPlayable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlist = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000
        media_0.m3u8
        """
        try playlist.write(to: directory.appendingPathComponent("stream.m3u8"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: directory.appendingPathComponent("init.mp4"))
        try Data([0]).write(to: directory.appendingPathComponent("segment_00001.m4s"))

        XCTAssertFalse(RemuxService.hasPlayableHLS(in: directory))
    }

    func testH264CommandDoesNotUseHVC1() throws {
        let plan = try makePlan(videoCodec: "h264", audioCodecs: [("aac", true)])
        let arguments = try RemuxService.buildFFmpegArguments(plan: plan)

        XCTAssertFalse(arguments.contains("hvc1"))
        XCTAssertTrue(arguments.containsSubsequence(["-map", "0:v:0"]))
        XCTAssertTrue(arguments.containsSubsequence(["-map", "0:1"]))
    }

    private func makePlan(
        videoCodec: String,
        videoProfile: String = "Main",
        audioCodecs: [(codec: String, isDefault: Bool)]
    ) throws -> RemuxPlan {
        let audioJSON = audioCodecs.enumerated().map { offset, audio in
            """
            {
              "index": \(offset + 1),
              "codec_type": "audio",
              "codec_name": "\(audio.codec)",
              "disposition": { "default": \(audio.isDefault ? 1 : 0) }
            }
            """
        }.joined(separator: ",")
        let probe = try decode("""
        {
          "streams": [
            {
              "index": 0,
              "codec_type": "video",
              "codec_name": "\(videoCodec)",
              "profile": "\(videoProfile)",
              "width": 3840,
              "height": 2160,
              "color_transfer": "smpte2084",
              "color_primaries": "bt2020",
              "color_space": "bt2020nc"
            },
            \(audioJSON)
          ],
          "format": { "format_name": "matroska,webm", "duration": "60.0" }
        }
        """)
        return try RemuxService.makePlan(inputURL: URL(fileURLWithPath: "/tmp/movie.mkv"), probe: probe)
    }

    private func decode(_ json: String) throws -> MediaProbe {
        try RemuxService.decodeProbe(Data(json.utf8))
    }

    func testStopAllTerminatesProcessesAndStopsServers() async throws {
        let service = RemuxService()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()

        let cacheKey = "test-stopall"
        await service.injectProcess(process, for: cacheKey)

        let activeBefore = await service.getActiveProcesses()
        XCTAssertEqual(activeBefore.count, 1)
        XCTAssertTrue(process.isRunning)

        await service.stopAll()
        process.waitUntilExit()

        let activeAfter = await service.getActiveProcesses()
        XCTAssertEqual(activeAfter.count, 0)
        XCTAssertFalse(process.isRunning)
    }
}

private extension Array where Element: Equatable {
    func containsSubsequence(_ subsequence: [Element]) -> Bool {
        guard !subsequence.isEmpty, subsequence.count <= count else { return false }
        return indices.contains { start in
            let end = index(start, offsetBy: subsequence.count, limitedBy: endIndex)
            guard let end else { return false }
            return Array(self[start..<end]) == subsequence
        }
    }
}
