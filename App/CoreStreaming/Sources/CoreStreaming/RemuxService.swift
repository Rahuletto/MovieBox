import CoreStorage
import Foundation

public actor RemuxService {
    private let fileManager: FileManager
    private var activeStreamingProcesses: [String: Process] = [:]
    private var hlsServers: [String: HLSCacheServer] = [:]
    private var hlsServerURLs: [String: URL] = [:]

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        Task {
            await pruneGlobalHLSCache()
        }
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
            let remuxPlan = try await plan(inputURL: inputURL)
            let verified = try await verifyRemuxMetadata(
                remuxPlan: remuxPlan,
                outputDirectory: outputDirectory
            )
            return RemuxResult(
                playlistURL: playlistURL,
                outputDirectory: outputDirectory,
                state: .completed,
                durationSeconds: remuxPlan.probe.duration,
                verifiedVideoColor: verified.video,
                verifiedAtmos: verified.atmos
            )
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

        let verified = try await verifyRemuxMetadata(
            remuxPlan: remuxPlan,
            outputDirectory: outputDirectory
        )
        return RemuxResult(
            playlistURL: playlistURL,
            outputDirectory: outputDirectory,
            state: .completed,
            durationSeconds: remuxPlan.probe.duration,
            verifiedVideoColor: verified.video,
            verifiedAtmos: verified.atmos
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
            let verified = try await verifyRemuxMetadata(
                remuxPlan: remuxPlan,
                outputDirectory: outputDirectory
            )
            return RemuxResult(
                playlistURL: playbackURL,
                outputDirectory: outputDirectory,
                state: .playable,
                durationSeconds: remuxPlan.probe.duration,
                verifiedVideoColor: verified.video,
                verifiedAtmos: verified.atmos
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
                let verified = try await verifyRemuxMetadata(
                    remuxPlan: remuxPlan,
                    outputDirectory: outputDirectory
                )
                return RemuxResult(
                    playlistURL: playbackURL,
                    outputDirectory: outputDirectory,
                    state: .playable,
                    durationSeconds: remuxPlan.probe.duration,
                    verifiedVideoColor: verified.video,
                    verifiedAtmos: verified.atmos
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

    public func stopAll() async {
        TorrentLog.info("[Remux] stopAll requested, terminating active processes count=\(activeStreamingProcesses.count)")
        for (cacheKey, process) in activeStreamingProcesses {
            if process.isRunning {
                TorrentLog.info("[Remux] terminating process pid=\(process.processIdentifier) for cacheKey=\(cacheKey)")
                process.terminate()
            }
            await stopHLSServer(cacheKey: cacheKey)
        }
        activeStreamingProcesses.removeAll()
    }

    #if DEBUG
    internal func injectProcess(_ process: Process, for cacheKey: String) {
        activeStreamingProcesses[cacheKey] = process
    }

    internal func getActiveProcesses() -> [String: Process] {
        activeStreamingProcesses
    }
    #endif

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

    private func hlsParentDirectory() throws -> URL {
        let baseURL = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return baseURL
            .appendingPathComponent("com.marban.MovieBox", isDirectory: true)
            .appendingPathComponent("HLS", isDirectory: true)
    }

    private func hlsOutputDirectory(cacheKey: String) throws -> URL {
        let parent = try hlsParentDirectory()
        let safeKey = Self.sanitizeCacheKey(cacheKey)
        return parent.appendingPathComponent(safeKey, isDirectory: true)
    }

    private func pruneGlobalHLSCache() {
        do {
            let parent = try hlsParentDirectory()
            guard fileManager.fileExists(atPath: parent.path) else { return }
            let contents = try fileManager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
            let now = Date()
            var prunedCount = 0
            for url in contents {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                
                if let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                   let modDate = resourceValues.contentModificationDate {
                    let age = now.timeIntervalSince(modDate)
                    // Clean directories older than 24 hours (86,400 seconds)
                    if age > 86400 {
                        try? fileManager.removeItem(at: url)
                        prunedCount += 1
                    }
                } else {
                    try? fileManager.removeItem(at: url)
                    prunedCount += 1
                }
            }
            if prunedCount > 0 {
                TorrentLog.info("[Remux] Cleaned up \(prunedCount) stale HLS cache directories from previous sessions.")
            }
        } catch {
            TorrentLog.warn("[Remux] Global HLS cache pruning failed: \(error.localizedDescription)")
        }
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
        let mdm = video?.colorMetadata.hasMasteringDisplay == true ? "yes" : "no"
        let cll = video?.colorMetadata.hasContentLightLevel == true ? "yes" : "no"
        let atmos = probe.audioStreams.contains { $0.atmosInfo.hasAtmosMetadata } ? "yes" : "no"
        TorrentLog.info("[Remux] probe video=\(video?.codecName ?? "none") hdr=\(hdr) dv=\(dv) mdm=\(mdm) cll=\(cll) audio=\(audio) atmos=\(atmos)")
    }

    private func verifyRemuxMetadata(
        remuxPlan: RemuxPlan,
        outputDirectory: URL
    ) async throws -> (video: VideoColorMetadata?, atmos: AtmosAudioInfo?) {
        let probeURLs = Self.outputProbeURLs(in: outputDirectory, decision: remuxPlan.decision)
        guard !probeURLs.isEmpty else {
            TorrentLog.warn("[Remux] hdr validate skipped — no probe target in \(outputDirectory.path)")
            return (remuxPlan.videoStream?.colorMetadata, remuxPlan.audioStream?.atmosInfo)
        }

        var mergedVideo: VideoColorMetadata?
        var mergedAtmos: AtmosAudioInfo?
        for probeURL in probeURLs {
            let outputProbe = try await probe(inputURL: probeURL)
            if let video = outputProbe.videoStreams.first?.colorMetadata {
                mergedVideo = Self.mergeVideoColorMetadata(mergedVideo, video)
            }
            if let atmos = remuxPlan.audioStream.flatMap({ planned in
                outputProbe.audioStreams.first(where: { $0.codecName == planned.codecName })?.atmosInfo
                    ?? outputProbe.audioStreams.first?.atmosInfo
            }) {
                mergedAtmos = Self.mergeAtmosInfo(mergedAtmos, atmos)
            }
        }

        let sourceVideo = remuxPlan.videoStream?.colorMetadata
        let sourceAtmos = remuxPlan.audioStream?.atmosInfo
        let outputVideo = mergedVideo
        let outputAtmos = mergedAtmos

        let result = HDRMetadataValidator.validate(
            sourceVideo: sourceVideo,
            sourceAtmos: sourceAtmos,
            outputVideo: outputVideo,
            outputAtmos: outputAtmos,
            plan: remuxPlan
        )

        for warning in result.warnings {
            TorrentLog.warn("[Remux] hdr validate warn \(warning.field): \(warning.message)")
        }

        if !result.passed {
            let detail = result.issues.map { "\($0.field): \($0.message)" }.joined(separator: "; ")
            TorrentLog.error("[Remux] hdr validate failed \(detail)")
            throw RemuxError.metadataStripped(detail)
        }

        let probedFiles = probeURLs.map(\.lastPathComponent).joined(separator: ",")
        TorrentLog.info("[Remux] hdr validate passed files=[\(probedFiles)] hdr=\(outputVideo?.dynamicRange.rawValue ?? "sdr") mdm=\(outputVideo?.hasMasteringDisplay == true ? "yes" : "no") cll=\(outputVideo?.hasContentLightLevel == true ? "yes" : "no") atmos=\(outputAtmos?.hasAtmosMetadata == true ? "yes" : "no")")
        return (outputVideo, outputAtmos)
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
    public let colorMetadata: VideoColorMetadata
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
    public let atmosInfo: AtmosAudioInfo
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
    /// Post-remux ffprobe of init.mp4 / segment — used for AVPlayer HUD and tone-map signaling.
    public let verifiedVideoColor: VideoColorMetadata?
    /// Verified E-AC-3 Atmos / multichannel for HDMI passthrough and Spatial Audio eligibility.
    public let verifiedAtmos: AtmosAudioInfo?

    public init(
        playlistURL: URL,
        outputDirectory: URL,
        state: RemuxSessionState,
        durationSeconds: Double? = nil,
        verifiedVideoColor: VideoColorMetadata? = nil,
        verifiedAtmos: AtmosAudioInfo? = nil
    ) {
        self.playlistURL = playlistURL
        self.outputDirectory = outputDirectory
        self.state = state
        self.durationSeconds = durationSeconds
        self.verifiedVideoColor = verifiedVideoColor
        self.verifiedAtmos = verifiedAtmos
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
    case metadataStripped(String)

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
        case .metadataStripped(let details):
            return "HDR/Dolby metadata was lost during remux and cannot tone-map correctly on this Mac. \(details)"
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
                let colorMetadata = SideDataParser.videoColorMetadata(
                    colorPrimaries: stream.colorPrimaries,
                    colorTransfer: stream.colorTransfer,
                    colorSpace: stream.colorSpace,
                    sideDataList: stream.sideDataList
                )
                return VideoStream(
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
                    dynamicRange: colorMetadata.dynamicRange,
                    hasDolbyVision: colorMetadata.dolbyVision != nil,
                    hasHDR10Plus: colorMetadata.hdr10Plus.present,
                    colorMetadata: colorMetadata
                )
            }
        let audioStreams = streams
            .filter { $0.codecType == "audio" }
            .map { stream in
                let codec = stream.codecName.normalizedCodecName
                let tagSearch = [stream.tags?.title, stream.tags?.language].compactMap { $0 }.joined(separator: " ")
                let atmosInfo = SideDataParser.atmosAudioInfo(
                    codecName: codec,
                    channels: stream.channels,
                    channelLayout: stream.channelLayout,
                    sideDataList: stream.sideDataList,
                    tagsSearch: tagSearch
                )
                return AudioStream(
                    index: stream.index,
                    codecName: codec,
                    profile: stream.profile,
                    channels: stream.channels,
                    channelLayout: stream.channelLayout,
                    sampleRate: stream.sampleRate,
                    bitRate: stream.bitRate,
                    language: stream.tags?.language,
                    title: stream.tags?.title,
                    isDefault: stream.disposition?.defaultValue == 1,
                    hasAtmosMetadata: atmosInfo.hasAtmosMetadata,
                    atmosInfo: atmosInfo
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
        arguments.append(contentsOf: ["-map_metadata", "0", "-copy_unknown", "-c", "copy"])
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
            "-movflags", "+write_colr",
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

    static func outputProbeURLs(in outputDirectory: URL, decision: RemuxPlanDecision) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)) ?? []
        switch decision {
        case .fmp4HLS:
            var urls: [URL] = []
            let initURL = outputDirectory.appendingPathComponent("init.mp4")
            if FileManager.default.fileExists(atPath: initURL.path) {
                urls.append(initURL)
            }
            let segments = files
                .filter { $0.pathExtension.lowercased() == "m4s" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .prefix(2)
            urls.append(contentsOf: segments)
            return urls
        case .tsHLS:
            return files
                .filter { $0.pathExtension.lowercased() == "ts" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .prefix(3)
                .map { $0 }
        case .unsupported:
            return []
        }
    }

    static func outputProbeURL(in outputDirectory: URL, decision: RemuxPlanDecision) -> URL? {
        outputProbeURLs(in: outputDirectory, decision: decision).first
    }

    static func mergeVideoColorMetadata(_ lhs: VideoColorMetadata?, _ rhs: VideoColorMetadata) -> VideoColorMetadata {
        guard let lhs else { return rhs }
        return VideoColorMetadata(
            colorPrimaries: rhs.colorPrimaries ?? lhs.colorPrimaries,
            colorTransfer: rhs.colorTransfer ?? lhs.colorTransfer,
            colorSpace: rhs.colorSpace ?? lhs.colorSpace,
            dynamicRange: maxDynamicRange(lhs.dynamicRange, rhs.dynamicRange),
            masteringDisplay: rhs.masteringDisplay ?? lhs.masteringDisplay,
            contentLightLevel: rhs.contentLightLevel ?? lhs.contentLightLevel,
            dolbyVision: rhs.dolbyVision ?? lhs.dolbyVision,
            hdr10Plus: HDR10PlusMetadata(present: lhs.hdr10Plus.present || rhs.hdr10Plus.present)
        )
    }

    static func mergeAtmosInfo(_ lhs: AtmosAudioInfo?, _ rhs: AtmosAudioInfo) -> AtmosAudioInfo {
        guard let lhs else { return rhs }
        let channels = [lhs.channelCount, rhs.channelCount].compactMap { $0 }.max()
        return AtmosAudioInfo(
            codecName: rhs.codecName,
            channelCount: channels,
            channelLayout: rhs.channelLayout ?? lhs.channelLayout,
            hasAtmosMetadata: lhs.hasAtmosMetadata || rhs.hasAtmosMetadata
        )
    }

    private static func maxDynamicRange(_ a: DynamicRange, _ b: DynamicRange) -> DynamicRange {
        let rank: (DynamicRange) -> Int = {
            switch $0 {
            case .sdr: 0
            case .hdr10: 1
            case .hlg: 2
            case .hdr10Plus: 3
            case .dolbyVision: 4
            }
        }
        return rank(a) >= rank(b) ? a : b
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
    let sideDataList: [FFProbeSideDataEntry]?

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
        sideDataList = try container.decodeIfPresent([FFProbeSideDataEntry].self, forKey: .sideDataList)
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
