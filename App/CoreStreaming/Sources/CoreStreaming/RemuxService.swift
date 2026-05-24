import CoreStorage
import Foundation

public actor RemuxService {
    private let fileManager: FileManager
    private var activeStreamingProcesses: [String: Process] = [:]
    private var hlsServers: [String: HLSCacheServer] = [:]
    private var hlsServerURLs: [String: URL] = [:]

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func probe(inputURL: URL) async throws -> MediaProbe {
        let ffprobeURL = try Self.resolveTool(named: "ffprobe")
        TorrentLog.info("[Remux] probe start file=\(inputURL.lastPathComponent) ffprobe=\(ffprobeURL.path)")
        let data = try runProbe(ffprobeURL: ffprobeURL, inputURL: inputURL)
        let probe = try Self.decodeProbe(data)
        logProbe(probe)
        return probe
    }

    public func plan(inputURL: URL) async throws -> RemuxPlan {
        let probe = try await probe(inputURL: inputURL)
        return try Self.makePlan(inputURL: inputURL, probe: probe)
    }

    public func remuxMKVToHLS(inputURL: URL, cacheKey: String) async throws -> RemuxResult {
        guard inputURL.pathExtension.lowercased() == "mkv" else {
            TorrentLog.info("[Remux] bypass non-mkv file=\(inputURL.lastPathComponent)")
            return RemuxResult(playlistURL: inputURL, outputDirectory: inputURL.deletingLastPathComponent(), state: .completed)
        }

        let ffprobeURL = try Self.resolveTool(named: "ffprobe")
        let ffmpegURL = try Self.resolveTool(named: "ffmpeg")
        let outputDirectory = try hlsOutputDirectory(cacheKey: cacheKey)
        let playlistURL = outputDirectory.appendingPathComponent("stream.m3u8")
        TorrentLog.info("[Remux] request file=\(inputURL.lastPathComponent) cacheKey=\(Self.sanitizeCacheKey(cacheKey)) ffprobe=\(ffprobeURL.path) ffmpeg=\(ffmpegURL.path) out=\(outputDirectory.path)")

        if Self.isCompleteHLSPlaylist(playlistURL) {
            TorrentLog.info("[Remux] cache hit complete playlist=\(playlistURL.path)")
            return RemuxResult(playlistURL: playlistURL, outputDirectory: outputDirectory, state: .completed)
        }

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try removeStaleHLSFiles(in: outputDirectory)
        TorrentLog.info("[Remux] cache miss prepared out=\(outputDirectory.path)")

        let remuxPlan = try await plan(inputURL: inputURL)
        let arguments = try Self.buildFFmpegArguments(plan: remuxPlan)
        TorrentLog.info("[Remux] plan=\(remuxPlan.decision.logLabel) video=\(remuxPlan.videoStream?.codecName ?? "none") copy audio=\(remuxPlan.audioStream?.index ?? -1):\(remuxPlan.audioStream?.codecName ?? "none") copy tag=\(remuxPlan.videoTag ?? "none")")

        let stderrURL = outputDirectory.appendingPathComponent("ffmpeg.stderr.log")
        try Data().write(to: stderrURL)
        let process = Process()
        process.executableURL = ffmpegURL
        process.currentDirectoryURL = outputDirectory
        process.arguments = arguments
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = Pipe()

        try process.run()
        TorrentLog.info("[Remux] started ffmpeg pid=\(process.processIdentifier) args=\(Self.redactedArguments(arguments))")
        process.waitUntilExit()
        try? (process.standardError as? FileHandle)?.close()

        if process.terminationStatus != 0 {
            let tail = Self.stderrTail(from: stderrURL)
            TorrentLog.error("[Remux] failed stderr=\(tail)")
            throw RemuxError.ffmpegFailed(tail)
        }

        guard Self.hasPlayableHLS(in: outputDirectory) else {
            throw RemuxError.outputNotFound
        }
        TorrentLog.info("[Remux] playable playlist=\(playlistURL.path) files=\(Self.hlsFileSummary(in: outputDirectory))")

        guard Self.isCompleteHLSPlaylist(playlistURL) else {
            throw RemuxError.incompletePlaylist
        }
        TorrentLog.info("[Remux] completed playlist=\(playlistURL.path)")
        return RemuxResult(
            playlistURL: playlistURL,
            outputDirectory: outputDirectory,
            state: .completed,
            durationSeconds: remuxPlan.probe.duration
        )
    }

    public func remuxStreamingMKVToHLS(inputURL: URL, cacheKey: String) async throws -> RemuxResult {
        TorrentLog.info("[Remux] streaming request begin url=\(inputURL.absoluteString) cacheKey=\(Self.sanitizeCacheKey(cacheKey))")
        let ffprobeURL = try Self.resolveTool(named: "ffprobe")
        let ffmpegURL = try Self.resolveTool(named: "ffmpeg")
        let outputDirectory = try hlsOutputDirectory(cacheKey: "stream-\(cacheKey)")
        let safeKey = Self.sanitizeCacheKey(cacheKey)

        let remuxPlan = try await plan(inputURL: inputURL)

        if let existing = activeStreamingProcesses[safeKey], existing.isRunning, Self.hasPlayableStreamingHLS(in: outputDirectory) {
            let playbackURL = try await ensureHLSServerURL(cacheKey: safeKey, outputDirectory: outputDirectory)
            TorrentLog.info("[Remux] streaming cache active playlist=\(playbackURL.absoluteString)")
            return RemuxResult(
                playlistURL: playbackURL,
                outputDirectory: outputDirectory,
                state: .playable,
                durationSeconds: remuxPlan.probe.duration
            )
        }

        activeStreamingProcesses[safeKey]?.terminate()
        activeStreamingProcesses[safeKey] = nil
        await stopHLSServer(cacheKey: safeKey)

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try removeStaleHLSFiles(in: outputDirectory)
        TorrentLog.info("[Remux] streaming request url=\(inputURL.absoluteString) cacheKey=\(safeKey) ffprobe=\(ffprobeURL.path) ffmpeg=\(ffmpegURL.path) out=\(outputDirectory.path)")

        let arguments = try Self.buildStreamingFFmpegArguments(plan: remuxPlan)
        let stderrURL = outputDirectory.appendingPathComponent("ffmpeg.stderr.log")
        try Data().write(to: stderrURL)

        let process = Process()
        process.executableURL = ffmpegURL
        process.currentDirectoryURL = outputDirectory
        process.arguments = arguments
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = Pipe()

        try process.run()
        activeStreamingProcesses[safeKey] = process
        TorrentLog.info("[Remux] streaming started ffmpeg pid=\(process.processIdentifier) args=\(Self.redactedArguments(arguments))")

        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            Self.normalizeStreamingPlaylist(at: outputDirectory.appendingPathComponent("stream.m3u8"))
            if Self.hasPlayableStreamingHLS(in: outputDirectory), process.isRunning {
                let playbackURL = try await ensureHLSServerURL(cacheKey: safeKey, outputDirectory: outputDirectory)
                TorrentLog.info("[Remux] streaming playable playlist=\(playbackURL.absoluteString) files=\(Self.hlsFileSummary(in: outputDirectory))")
                return RemuxResult(
                    playlistURL: playbackURL,
                    outputDirectory: outputDirectory,
                    state: .playable,
                    durationSeconds: remuxPlan.probe.duration
                )
            }
            if !process.isRunning {
                let tail = Self.stderrTail(from: stderrURL)
                TorrentLog.error("[Remux] streaming failed before playable status=\(process.terminationStatus) stderr=\(tail)")
                activeStreamingProcesses[safeKey] = nil
                await stopHLSServer(cacheKey: safeKey)
                throw RemuxError.ffmpegFailed(tail)
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        let tail = Self.stderrTail(from: stderrURL)
        TorrentLog.error("[Remux] streaming timed out waiting for first segment stderr=\(tail)")
        throw RemuxError.ffmpegFailed("Timed out waiting for HLS remux to become playable.\n\(tail)")
    }

    private func ensureHLSServerURL(cacheKey: String, outputDirectory: URL) async throws -> URL {
        if let url = hlsServerURLs[cacheKey] {
            return url
        }
        let server = await MainActor.run { HLSCacheServer() }
        let url = try await server.start(rootDirectory: outputDirectory)
        hlsServers[cacheKey] = server
        hlsServerURLs[cacheKey] = url
        return url
    }

    private func stopHLSServer(cacheKey: String) async {
        hlsServerURLs.removeValue(forKey: cacheKey)
        guard let server = hlsServers.removeValue(forKey: cacheKey) else { return }
        await MainActor.run {
            server.stop()
        }
    }

    public func detectHDR(inputURL: URL) async throws -> HDRInfo? {
        let probe = try await probe(inputURL: inputURL)
        guard let video = probe.videoStreams.first else { return nil }
        let resolution = "\(video.width ?? 0)x\(video.height ?? 0)"
        return HDRInfo(
            isHDR: video.dynamicRange != .sdr,
            hdrType: HDRType(dynamicRange: video.dynamicRange),
            codec: video.codecName,
            profile: video.profile ?? "",
            bitDepth: video.bitsPerRawSample ?? video.bitsPerSample ?? "8",
            resolution: resolution
        )
    }

    private func runProbe(ffprobeURL: URL, inputURL: URL) throws -> Data {
        let process = Process()
        process.executableURL = ffprobeURL
        let probeInput = inputURL.isFileURL ? inputURL.path : inputURL.absoluteString
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            "-show_entries", "stream=index,codec_type,codec_name,profile,pix_fmt,bits_per_raw_sample,bits_per_sample,width,height,r_frame_rate,avg_frame_rate,color_primaries,color_transfer,color_space,channels,channel_layout,sample_rate,bit_rate,disposition:stream_tags=language,title:stream_side_data",
            "-i", probeInput
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? "ffprobe failed"
            TorrentLog.error("[Remux] ffprobe failed status=\(process.terminationStatus) stderr=\(Self.usefulTail(message))")
            throw RemuxError.ffprobeFailed(Self.usefulTail(message))
        }
        TorrentLog.info("[Remux] ffprobe completed bytes=\(outputData.count)")
        return outputData
    }

    private func hlsOutputDirectory(cacheKey: String) throws -> URL {
        let baseURL = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let safeKey = Self.sanitizeCacheKey(cacheKey)
        return baseURL
            .appendingPathComponent("com.marban.MovieBox", isDirectory: true)
            .appendingPathComponent("HLS", isDirectory: true)
            .appendingPathComponent(safeKey, isDirectory: true)
    }

    private func removeStaleHLSFiles(in directory: URL) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in contents where ["m3u8", "mp4", "m4s", "ts", "mpd", "log"].contains(url.pathExtension.lowercased()) {
            try fileManager.removeItem(at: url)
        }
        TorrentLog.info("[Remux] removed stale hls files count=\(contents.count) out=\(directory.path)")
    }

    private func logProbe(_ probe: MediaProbe) {
        let video = probe.videoStreams.first
        let audio = probe.audioStreams.map { "\($0.index):\($0.codecName)" }.joined(separator: ",")
        let hdr = video?.dynamicRange.rawValue ?? "unknown"
        let dv = video?.hasDolbyVision == true ? "yes" : "no"
        let atmos = probe.audioStreams.contains { $0.hasAtmosMetadata } ? "yes" : "no"
        TorrentLog.info("[Remux] probe video=\(video?.codecName ?? "none") hdr=\(hdr) dv=\(dv) audio=\(audio) atmos=\(atmos)")
    }
}

public struct MediaProbe: Sendable {
    public let formatName: String?
    public let duration: Double?
    public let videoStreams: [VideoStream]
    public let audioStreams: [AudioStream]
    public let subtitleStreams: [SubtitleStream]

    public init(formatName: String?, duration: Double?, videoStreams: [VideoStream], audioStreams: [AudioStream], subtitleStreams: [SubtitleStream]) {
        self.formatName = formatName
        self.duration = duration
        self.videoStreams = videoStreams
        self.audioStreams = audioStreams
        self.subtitleStreams = subtitleStreams
    }
}

public struct VideoStream: Sendable {
    public let index: Int
    public let codecName: String
    public let profile: String?
    public let pixelFormat: String?
    public let bitsPerRawSample: String?
    public let bitsPerSample: String?
    public let width: Int?
    public let height: Int?
    public let averageFrameRate: String?
    public let realFrameRate: String?
    public let colorPrimaries: String?
    public let colorTransfer: String?
    public let colorSpace: String?
    public let dynamicRange: DynamicRange
    public let hasDolbyVision: Bool
    public let hasHDR10Plus: Bool
}

public struct AudioStream: Sendable {
    public let index: Int
    public let codecName: String
    public let profile: String?
    public let channels: Int?
    public let channelLayout: String?
    public let sampleRate: String?
    public let bitRate: String?
    public let language: String?
    public let title: String?
    public let isDefault: Bool
    public let hasAtmosMetadata: Bool
}

public struct SubtitleStream: Sendable {
    public let index: Int
    public let codecName: String
    public let language: String?
    public let title: String?
}

public enum DynamicRange: String, Sendable {
    case sdr
    case hdr10
    case hdr10Plus
    case hlg
    case dolbyVision
}

public struct RemuxPlan: Sendable {
    public let inputURL: URL
    public let probe: MediaProbe
    public let decision: RemuxPlanDecision
    public let videoStream: VideoStream?
    public let audioStream: AudioStream?
    public let videoTag: String?
    public let unsupportedReason: String?
}

public enum RemuxPlanDecision: Sendable, Equatable {
    /// Fragmented MP4 segments — required for HEVC per Apple HLS authoring.
    case fmp4HLS
    /// MPEG-TS segments — lossless path for H.264 + AAC/AC-3/E-AC-3 (AVPlayer-friendly Dolby).
    case tsHLS
    case unsupported

    var logLabel: String {
        switch self {
        case .fmp4HLS: "fmp4_hls"
        case .tsHLS: "ts_hls"
        case .unsupported: "unsupported"
        }
    }
}

public struct RemuxResult: Sendable {
    public let playlistURL: URL
    public let outputDirectory: URL
    public let state: RemuxSessionState
    public let durationSeconds: Double?

    public init(playlistURL: URL, outputDirectory: URL, state: RemuxSessionState, durationSeconds: Double? = nil) {
        self.playlistURL = playlistURL
        self.outputDirectory = outputDirectory
        self.state = state
        self.durationSeconds = durationSeconds
    }
}

public enum RemuxSessionState: Sendable, Equatable {
    case preparing
    case remuxing
    case playable
    case completed
    case failed(String)
}

public enum HDRType: String, Sendable {
    case dolbyVision = "Dolby Vision"
    case hdr10Plus = "HDR10+"
    case hdr10 = "HDR10"
    case hlg = "HLG"
}

public struct HDRInfo: Sendable {
    public let isHDR: Bool
    public let hdrType: HDRType?
    public let codec: String
    public let profile: String
    public let bitDepth: String
    public let resolution: String

    public init(isHDR: Bool, hdrType: HDRType?, codec: String, profile: String, bitDepth: String, resolution: String) {
        self.isHDR = isHDR
        self.hdrType = hdrType
        self.codec = codec
        self.profile = profile
        self.bitDepth = bitDepth
        self.resolution = resolution
    }
}

public enum RemuxError: Error, LocalizedError, Equatable {
    case ffmpegFailed(String)
    case ffprobeFailed(String)
    case outputNotFound
    case incompletePlaylist
    case ffmpegNotFound
    case ffprobeNotFound
    case unsupported(String)
    case invalidProbe(String)

    public var errorDescription: String? {
        switch self {
        case .ffmpegFailed(let message):
            return "ffmpeg remux failed: \(message)"
        case .ffprobeFailed(let message):
            return "ffprobe failed: \(message)"
        case .outputNotFound:
            return "Remux output file not found"
        case .incompletePlaylist:
            return "Remux playlist did not complete"
        case .ffmpegNotFound:
            return "ffmpeg not found in the app bundle"
        case .ffprobeNotFound:
            return "ffprobe not found in the app bundle"
        case .unsupported(let message):
            return message
        case .invalidProbe(let message):
            return "Invalid media probe: \(message)"
        }
    }
}

extension RemuxService {
    static func decodeProbe(_ data: Data) throws -> MediaProbe {
        let response: FFProbeResponse
        do {
            response = try JSONDecoder().decode(FFProbeResponse.self, from: data)
        } catch {
            let snippet = String(data: data.prefix(512), encoding: .utf8) ?? "<binary>"
            TorrentLog.error("[Remux] ffprobe json decode failed error=\(error) snippet=\(snippet)")
            throw RemuxError.invalidProbe(error.localizedDescription)
        }
        let streams = response.streams ?? []
        let videoStreams = streams
            .filter { $0.codecType == "video" }
            .map { stream in
                VideoStream(
                    index: stream.index,
                    codecName: stream.codecName.normalizedCodecName,
                    profile: stream.profile,
                    pixelFormat: stream.pixFmt,
                    bitsPerRawSample: stream.bitsPerRawSample,
                    bitsPerSample: stream.bitsPerSample,
                    width: stream.width,
                    height: stream.height,
                    averageFrameRate: stream.avgFrameRate,
                    realFrameRate: stream.rFrameRate,
                    colorPrimaries: stream.colorPrimaries,
                    colorTransfer: stream.colorTransfer,
                    colorSpace: stream.colorSpace,
                    dynamicRange: dynamicRange(for: stream),
                    hasDolbyVision: hasDolbyVision(stream),
                    hasHDR10Plus: hasHDR10Plus(stream)
                )
            }
        let audioStreams = streams
            .filter { $0.codecType == "audio" }
            .map { stream in
                AudioStream(
                    index: stream.index,
                    codecName: stream.codecName.normalizedCodecName,
                    profile: stream.profile,
                    channels: stream.channels,
                    channelLayout: stream.channelLayout,
                    sampleRate: stream.sampleRate,
                    bitRate: stream.bitRate,
                    language: stream.tags?.language,
                    title: stream.tags?.title,
                    isDefault: stream.disposition?.defaultValue == 1,
                    hasAtmosMetadata: hasAtmosMetadata(stream)
                )
            }
        let subtitleStreams = streams
            .filter { $0.codecType == "subtitle" }
            .map { stream in
                SubtitleStream(
                    index: stream.index,
                    codecName: stream.codecName.normalizedCodecName,
                    language: stream.tags?.language,
                    title: stream.tags?.title
                )
            }
        return MediaProbe(
            formatName: response.format?.formatName,
            duration: response.format?.duration.flatMap(Double.init),
            videoStreams: videoStreams,
            audioStreams: audioStreams,
            subtitleStreams: subtitleStreams
        )
    }

    static func makePlan(inputURL: URL, probe: MediaProbe) throws -> RemuxPlan {
        guard let video = probe.videoStreams.first else {
            return unsupported(inputURL: inputURL, probe: probe, reason: "No video stream found.")
        }
        guard ["h264", "hevc"].contains(video.codecName) else {
            let reason = "Video codec \(video.codecName) cannot be remuxed losslessly for AVPlayer."
            TorrentLog.warn("[Remux] unsupported video=\(video.codecName) reason=\(reason)")
            return unsupported(inputURL: inputURL, probe: probe, video: video, reason: reason)
        }

        let compatibleAudio = probe.audioStreams.filter { ["aac", "ac3", "eac3"].contains($0.codecName) }
        guard let audio = compatibleAudio.first(where: \.isDefault) ?? compatibleAudio.first else {
            let codec = probe.audioStreams.first?.codecName ?? "none"
            let reason = "Audio codec \(codec) is not AVPlayer-compatible in strict preservation mode."
            TorrentLog.warn("[Remux] unsupported audio=\(codec) reason=\(reason)")
            return unsupported(inputURL: inputURL, probe: probe, video: video, reason: reason)
        }

        // Apple requires fMP4 for HEVC; H.264 + Dolby is remuxed to MPEG-TS HLS (lossless).
        let decision: RemuxPlanDecision = video.codecName == "hevc" ? .fmp4HLS : .tsHLS

        return RemuxPlan(
            inputURL: inputURL,
            probe: probe,
            decision: decision,
            videoStream: video,
            audioStream: audio,
            videoTag: video.codecName == "hevc" ? "hvc1" : nil,
            unsupportedReason: nil
        )
    }

    static func buildFFmpegArguments(plan: RemuxPlan) throws -> [String] {
        switch plan.decision {
        case .fmp4HLS:
            return buildFMP4HLSArguments(plan: plan, input: plan.inputURL.path, streaming: false)
        case .tsHLS:
            return buildTSHLSArguments(plan: plan, input: plan.inputURL.path, streaming: false)
        case .unsupported:
            throw RemuxError.unsupported(plan.unsupportedReason ?? "Unsupported media for AVPlayer remux.")
        }
    }

    static func buildStreamingFFmpegArguments(plan: RemuxPlan) throws -> [String] {
        switch plan.decision {
        case .fmp4HLS:
            return buildFMP4HLSArguments(plan: plan, input: plan.inputURL.absoluteString, streaming: true)
        case .tsHLS:
            return buildTSHLSArguments(plan: plan, input: plan.inputURL.absoluteString, streaming: true)
        case .unsupported:
            throw RemuxError.unsupported(plan.unsupportedReason ?? "Unsupported media for AVPlayer remux.")
        }
    }

    private static func buildLosslessStreamMaps(plan: RemuxPlan) -> [String] {
        // Must follow `-i` on this ffmpeg build (before `-i` fails for file and HTTP inputs).
        var arguments = ["-map_chapters", "-1", "-map", "0:v:0"]
        if let audio = plan.audioStream {
            arguments.append(contentsOf: ["-map", "0:\(audio.index)"])
        }
        arguments.append(contentsOf: ["-c", "copy"])
        if let videoTag = plan.videoTag {
            arguments.append(contentsOf: ["-tag:v", videoTag])
        }
        if let audioCodec = plan.audioStream?.codecName {
            switch audioCodec {
            case "eac3":
                arguments.append(contentsOf: ["-tag:a", "ec-3"])
            case "ac3":
                arguments.append(contentsOf: ["-tag:a", "ac-3"])
            default:
                break
            }
        }
        return arguments
    }

    private static func buildInputArguments(input: String) -> [String] {
        ["-hide_banner", "-fflags", "+genpts", "-i", input]
    }

    private static func buildFMP4HLSArguments(plan: RemuxPlan, input: String, streaming: Bool) -> [String] {
        var arguments = buildInputArguments(input: input)
        arguments.append(contentsOf: buildLosslessStreamMaps(plan: plan))
        arguments.append(contentsOf: [
            "-dn",
            "-sn",
            "-avoid_negative_ts", "make_zero",
            "-reset_timestamps", "1",
            "-f", "hls",
            "-hls_segment_type", "fmp4",
            "-hls_time", "4",
            "-hls_fmp4_init_filename", "init.mp4",
            "-hls_segment_filename", "segment_%05d.m4s",
        ])
        if streaming {
            arguments.append(contentsOf: [
                "-hls_list_size", "0",
                "-hls_playlist_type", "event",
                "-hls_flags", "append_list+independent_segments",
            ])
        } else {
            arguments.append(contentsOf: [
                "-hls_playlist_type", "vod",
                "-hls_flags", "independent_segments",
            ])
        }
        arguments.append(contentsOf: ["-y", "stream.m3u8"])
        return arguments
    }

    private static func buildTSHLSArguments(plan: RemuxPlan, input: String, streaming: Bool) -> [String] {
        var arguments = buildInputArguments(input: input)
        arguments.append(contentsOf: buildLosslessStreamMaps(plan: plan))
        arguments.append(contentsOf: [
            "-dn",
            "-sn",
            "-avoid_negative_ts", "make_zero",
            "-reset_timestamps", "1",
            "-f", "hls",
            "-hls_time", "4",
            "-hls_segment_filename", "segment_%05d.ts",
        ])
        if streaming {
            arguments.append(contentsOf: [
                "-hls_list_size", "0",
                "-hls_playlist_type", "event",
                "-hls_flags", "append_list+independent_segments",
            ])
        } else {
            arguments.append(contentsOf: [
                "-hls_playlist_type", "vod",
                "-hls_flags", "independent_segments",
            ])
        }
        arguments.append(contentsOf: ["-y", "stream.m3u8"])
        return arguments
    }

    static func redactedArguments(_ arguments: [String]) -> String {
        arguments.map { argument in
            if argument.hasPrefix("/") {
                return URL(fileURLWithPath: argument).lastPathComponent
            }
            return argument
        }.joined(separator: " ")
    }

    static func resolveTool(named name: String) throws -> URL {
        if let url = FFmpegToolLocator.url(for: name) {
            return url
        }
        if name == "ffprobe" { throw RemuxError.ffprobeNotFound }
        throw RemuxError.ffmpegNotFound
    }

    static func hasPlayableStreamingHLS(in directory: URL) -> Bool {
        guard hasPlayableHLS(in: directory) else { return false }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let segmentCount = files.filter {
            let ext = $0.pathExtension.lowercased()
            return ext == "m4s" || ext == "ts"
        }.count
        return segmentCount >= 3
    }

    static func normalizeStreamingPlaylist(at playlistURL: URL) {
        guard var lines = try? String(contentsOf: playlistURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        else { return }

        if let mapIndex = lines.firstIndex(where: { $0.contains("#EXT-X-MAP") }) {
            let nextIndex = mapIndex + 1
            if nextIndex < lines.count,
               lines[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines) == "#EXT-X-DISCONTINUITY" {
                lines.remove(at: nextIndex)
            }
        }

        if !lines.contains(where: { $0.contains("#EXT-X-PLAYLIST-TYPE:EVENT") }),
           let versionIndex = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-VERSION") }) {
            lines.insert("#EXT-X-PLAYLIST-TYPE:EVENT", at: versionIndex + 1)
        }

        let normalized = lines.joined(separator: "\n")
        guard normalized != (try? String(contentsOf: playlistURL, encoding: .utf8)) else { return }
        try? normalized.write(to: playlistURL, atomically: true, encoding: .utf8)
    }

    static func hasPlayableHLS(in directory: URL) -> Bool {
        let playlistURL = directory.appendingPathComponent("stream.m3u8")
        guard FileManager.default.fileExists(atPath: playlistURL.path),
              let playlist = try? String(contentsOf: playlistURL, encoding: .utf8)
        else { return false }

        if playlist.contains("#EXT-X-MAP"), playlist.contains(".m4s") {
            let initSegment = directory.appendingPathComponent("init.mp4")
            guard FileManager.default.fileExists(atPath: initSegment.path),
                  hasCompletedSegment(withExtension: "m4s", in: directory)
            else { return false }
            return true
        }

        if playlist.contains(".ts") || hasCompletedSegment(withExtension: "ts", in: directory) {
            return hasCompletedSegment(withExtension: "ts", in: directory)
        }

        if playlist.contains("#EXT-X-STREAM-INF") {
            let referenced = hlsPlaylistReferences(from: playlist)
            guard !referenced.isEmpty else { return false }
            return referenced.allSatisfy { reference in
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(reference).path)
            }
        }

        return false
    }

    static func hlsFileSummary(in directory: URL) -> String {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let m4sCount = files.filter { $0.pathExtension.lowercased() == "m4s" }.count
        let tsCount = files.filter { $0.pathExtension.lowercased() == "ts" }.count
        let hasPlaylist = files.contains { $0.lastPathComponent == "stream.m3u8" }
        let hasInit = files.contains { $0.lastPathComponent == "init.mp4" }
        let valid = hasPlayableHLS(in: directory)
        return "playlist=\(hasPlaylist) init=\(hasInit) m4s=\(m4sCount) ts=\(tsCount) valid=\(valid)"
    }

    private static func hasCompletedSegment(withExtension fileExtension: String, in directory: URL) -> Bool {
        let segments = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return segments.contains { url in
            url.pathExtension.lowercased() == fileExtension && !url.lastPathComponent.hasSuffix(".tmp")
        }
    }

    private static func hlsPlaylistReferences(from playlist: String) -> [String] {
        playlist
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty
                    && !line.hasPrefix("#")
                    && line.hasSuffix(".m3u8")
            }
    }

    static func isCompleteHLSPlaylist(_ url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        let playlists = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "m3u8" } ?? [url]
        return playlists.contains { playlist in
            guard let text = try? String(contentsOf: playlist, encoding: .utf8) else { return false }
            return text.contains("#EXT-X-ENDLIST")
        }
    }

    static func stderrTail(from url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "Unknown ffmpeg error" }
        return usefulTail(text)
    }

    static func usefulTail(_ text: String, maxLines: Int = 24) -> String {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let tail = lines.suffix(maxLines).joined(separator: "\n")
        return tail.isEmpty ? "Unknown error" : tail
    }

    static func sanitizeCacheKey(_ key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return value.isEmpty ? UUID().uuidString : value
    }

    private static func unsupported(inputURL: URL, probe: MediaProbe, video: VideoStream? = nil, reason: String) -> RemuxPlan {
        RemuxPlan(
            inputURL: inputURL,
            probe: probe,
            decision: .unsupported,
            videoStream: video,
            audioStream: nil,
            videoTag: nil,
            unsupportedReason: reason
        )
    }

    private static func dynamicRange(for stream: FFProbeStream) -> DynamicRange {
        if hasDolbyVision(stream) { return .dolbyVision }
        if hasHDR10Plus(stream) { return .hdr10Plus }
        if stream.colorTransfer == "arib-std-b67" { return .hlg }
        if stream.colorTransfer == "smpte2084" || stream.colorPrimaries == "bt2020" || stream.colorSpace == "bt2020nc" {
            return .hdr10
        }
        return .sdr
    }

    private static func hasDolbyVision(_ stream: FFProbeStream) -> Bool {
        let haystack = stream.searchableMetadata
        return haystack.contains("dolby vision") || haystack.contains("dovi") || haystack.contains("dv profile")
    }

    private static func hasHDR10Plus(_ stream: FFProbeStream) -> Bool {
        let haystack = stream.searchableMetadata
        return haystack.contains("hdr10+") || haystack.contains("smpte2094") || haystack.contains("dynamic hdr plus")
    }

    private static func hasAtmosMetadata(_ stream: FFProbeStream) -> Bool {
        let haystack = stream.searchableMetadata
        return haystack.contains("atmos") || haystack.contains("joc")
    }
}

private extension HDRType {
    init?(dynamicRange: DynamicRange) {
        switch dynamicRange {
        case .dolbyVision: self = .dolbyVision
        case .hdr10Plus: self = .hdr10Plus
        case .hdr10: self = .hdr10
        case .hlg: self = .hlg
        case .sdr: return nil
        }
    }
}

private extension String? {
    var normalizedCodecName: String {
        (self ?? "unknown").lowercased()
    }
}

private struct FFProbeResponse: Decodable {
    let streams: [FFProbeStream]?
    let format: FFProbeFormat?
}

private struct FFProbeFormat: Decodable {
    let formatName: String?
    let duration: String?

    enum CodingKeys: String, CodingKey {
        case formatName = "format_name"
        case duration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatName = try container.decodeIfPresent(String.self, forKey: .formatName)
        duration = container.flexString(forKey: .duration)
    }
}

private struct FFProbeStream: Decodable {
    let index: Int
    let codecType: String?
    let codecName: String?
    let profile: String?
    let pixFmt: String?
    let bitsPerRawSample: String?
    let bitsPerSample: String?
    let width: Int?
    let height: Int?
    let rFrameRate: String?
    let avgFrameRate: String?
    let colorPrimaries: String?
    let colorTransfer: String?
    let colorSpace: String?
    let channels: Int?
    let channelLayout: String?
    let sampleRate: String?
    let bitRate: String?
    let disposition: FFProbeDisposition?
    let tags: FFProbeTags?
    let sideDataList: [FFProbeSideData]?

    enum CodingKeys: String, CodingKey {
        case index
        case codecType = "codec_type"
        case codecName = "codec_name"
        case profile
        case pixFmt = "pix_fmt"
        case bitsPerRawSample = "bits_per_raw_sample"
        case bitsPerSample = "bits_per_sample"
        case width
        case height
        case rFrameRate = "r_frame_rate"
        case avgFrameRate = "avg_frame_rate"
        case colorPrimaries = "color_primaries"
        case colorTransfer = "color_transfer"
        case colorSpace = "color_space"
        case channels
        case channelLayout = "channel_layout"
        case sampleRate = "sample_rate"
        case bitRate = "bit_rate"
        case disposition
        case tags
        case sideDataList = "side_data_list"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.flexInt(forKey: .index) ?? 0
        codecType = try container.decodeIfPresent(String.self, forKey: .codecType)
        codecName = try container.decodeIfPresent(String.self, forKey: .codecName)
        profile = container.flexString(forKey: .profile)
        pixFmt = try container.decodeIfPresent(String.self, forKey: .pixFmt)
        bitsPerRawSample = container.flexString(forKey: .bitsPerRawSample)
        bitsPerSample = container.flexString(forKey: .bitsPerSample)
        width = try container.flexInt(forKey: .width)
        height = try container.flexInt(forKey: .height)
        rFrameRate = try container.decodeIfPresent(String.self, forKey: .rFrameRate)
        avgFrameRate = try container.decodeIfPresent(String.self, forKey: .avgFrameRate)
        colorPrimaries = try container.decodeIfPresent(String.self, forKey: .colorPrimaries)
        colorTransfer = try container.decodeIfPresent(String.self, forKey: .colorTransfer)
        colorSpace = try container.decodeIfPresent(String.self, forKey: .colorSpace)
        channels = try container.flexInt(forKey: .channels)
        channelLayout = try container.decodeIfPresent(String.self, forKey: .channelLayout)
        sampleRate = container.flexString(forKey: .sampleRate)
        bitRate = container.flexString(forKey: .bitRate)
        disposition = try container.decodeIfPresent(FFProbeDisposition.self, forKey: .disposition)
        tags = try container.decodeIfPresent(FFProbeTags.self, forKey: .tags)
        sideDataList = try container.decodeIfPresent([FFProbeSideData].self, forKey: .sideDataList)
    }

    var searchableMetadata: String {
        var values = [
            codecName,
            profile,
            pixFmt,
            colorPrimaries,
            colorTransfer,
            colorSpace,
            tags?.language,
            tags?.title
        ].compactMap { $0 }
        values.append(contentsOf: sideDataList?.flatMap(\.values) ?? [])
        return values.joined(separator: " ").lowercased()
    }
}

private struct FFProbeDisposition: Decodable {
    let defaultValue: Int?

    enum CodingKeys: String, CodingKey {
        case defaultValue = "default"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Int.self, forKey: .defaultValue) {
            defaultValue = value
        } else if let value = try container.decodeIfPresent(Bool.self, forKey: .defaultValue) {
            defaultValue = value ? 1 : 0
        } else {
            defaultValue = nil
        }
    }
}

private struct FFProbeTags: Decodable {
    let language: String?
    let title: String?
}

private struct FFProbeSideData: Decodable {
    let values: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var parsed: [String] = []
        for key in container.allKeys {
            if let value = try? container.decode(String.self, forKey: key) {
                parsed.append(value)
            } else if let value = try? container.decode(Int.self, forKey: key) {
                parsed.append(String(value))
            } else if let value = try? container.decode(Double.self, forKey: key) {
                parsed.append(String(value))
            }
        }
        values = parsed
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer {
    func flexString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
        }
        return nil
    }

    func flexInt(forKey key: Key) throws -> Int? {
        if let value = try decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = flexString(forKey: key) { return Int(value) }
        return nil
    }
}
