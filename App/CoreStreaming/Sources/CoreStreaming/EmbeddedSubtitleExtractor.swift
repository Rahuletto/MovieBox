import Foundation

public struct EmbeddedSubtitleTrack: Sendable, Identifiable, Hashable {
    public let index: Int
    public let language: String
    public let title: String
    public let codec: String

    public var id: Int { index }

    public var displayName: String {
        let lang = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty, !lang.isEmpty, label.lowercased() != lang.lowercased() {
            return "\(lang) — \(label)"
        }
        if !label.isEmpty { return label }
        if !lang.isEmpty { return lang }
        return "Track \(index + 1)"
    }

    public init(index: Int, language: String, title: String, codec: String) {
        self.index = index
        self.language = language
        self.title = title
        self.codec = codec
    }
}

/// Lists and extracts subtitle streams baked into a local video file via ffmpeg/ffprobe.
public enum EmbeddedSubtitleExtractor {
    private static let ffmpegPath: String = {
        if let bundlePath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) {
            return bundlePath
        }
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ffmpeg") {
            return "/opt/homebrew/bin/ffmpeg"
        }
        return "/usr/local/bin/ffmpeg"
    }()

    private static let ffprobePath: String = {
        let sibling = (ffmpegPath as NSString).deletingLastPathComponent.appending("/ffprobe")
        if FileManager.default.fileExists(atPath: sibling) {
            return sibling
        }
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ffprobe") {
            return "/opt/homebrew/bin/ffprobe"
        }
        return "/usr/local/bin/ffprobe"
    }()

    private static let minimumPartialProbeFileBytes: Int64 = 512 * 1024
    private static let minimumExtractFileBytes: Int64 = 2 * 1024 * 1024

    public static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: ffmpegPath)
    }

    /// Probes a media file for embedded subtitle streams. Returns empty if ffmpeg is missing or the slice is too small.
    public static func probe(mediaFileURL: URL, isCompleteFile: Bool = false) async -> [EmbeddedSubtitleTrack] {
        guard isAvailable else { return [] }
        if !isCompleteFile {
            guard let fileSize = try? FileManager.default.attributesOfItem(atPath: mediaFileURL.path)[.size] as? Int64,
                  fileSize >= minimumPartialProbeFileBytes else {
                return []
            }
        }

        return await Task.detached(priority: .utility) {
            runProbe(mediaFileURL: mediaFileURL)
        }.value
    }

    /// Extracts one embedded subtitle stream to SRT (`-map 0:s:N`).
    public static func extract(
        mediaFileURL: URL,
        streamIndex: Int,
        outputURL: URL
    ) async throws {
        guard isAvailable else { throw EmbeddedSubtitleError.ffmpegNotFound }
        if let fileSize = try? FileManager.default.attributesOfItem(atPath: mediaFileURL.path)[.size] as? Int64,
           fileSize < minimumExtractFileBytes {
            throw EmbeddedSubtitleError.fileTooSmall
        }

        try await Task.detached(priority: .utility) {
            try runExtract(mediaFileURL: mediaFileURL, streamIndex: streamIndex, outputURL: outputURL)
        }.value
    }

    private static func runProbe(mediaFileURL: URL) -> [EmbeddedSubtitleTrack] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-print_format", "json",
            "-show_streams",
            "-select_streams", "s",
            mediaFileURL.path,
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0 else { return [] }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]] else {
            return []
        }

        var tracks: [EmbeddedSubtitleTrack] = []
        for (subtitleIndex, stream) in streams.enumerated() {
            let tags = stream["tags"] as? [String: Any]
            let language = (tags?["language"] as? String) ?? "unknown"
            let title = (tags?["title"] as? String) ?? ""
            let codec = (stream["codec_name"] as? String) ?? "sub"
            tracks.append(
                EmbeddedSubtitleTrack(index: subtitleIndex, language: language, title: title, codec: codec)
            )
        }
        return tracks
    }

    private static func runExtract(
        mediaFileURL: URL,
        streamIndex: Int,
        outputURL: URL
    ) throws {
        let parent = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", mediaFileURL.path,
            "-map", "0:s:\(streamIndex)",
            "-c:s", "srt",
            outputURL.path,
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: outputURL.path) else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ffmpeg failed"
            throw EmbeddedSubtitleError.extractionFailed(message)
        }
    }
}

public enum EmbeddedSubtitleError: Error, LocalizedError {
    case ffmpegNotFound
    case fileTooSmall
    case extractionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            "ffmpeg was not found. Install with: brew install ffmpeg"
        case .fileTooSmall:
            "Not enough of the video file is downloaded yet to extract subtitles. Keep buffering, or pick an “In video” track that uses the player’s built-in captions."
        case .extractionFailed(let message):
            "Could not extract embedded subtitles: \(message)"
        }
    }
}
