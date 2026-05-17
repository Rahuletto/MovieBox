import Foundation

public actor RemuxService {
    private static let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil)
        ?? "/opt/homebrew/bin/ffmpeg"
        ?? "/usr/local/bin/ffmpeg"

    public init() {}

    public func remuxMKVToMP4(inputURL: URL) async throws -> URL {
        let fileExtension = inputURL.pathExtension.lowercased()
        guard fileExtension == "mkv" else {
            return inputURL
        }

        let outputURL = inputURL.deletingPathExtension().appendingPathExtension("mp4")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.ffmpegPath)
        process.arguments = [
            "-i", inputURL.path,
            "-c", "copy",
            "-movflags", "frag_keyframe+empty_moov",
            "-y",
            outputURL.path
        ]

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw RemuxError.ffmpegFailed(errorMessage)
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw RemuxError.outputNotFound
        }

        return outputURL
    }

    public func detectHDR(inputURL: URL) async throws -> HDRInfo? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.ffmpegPath)
        process.arguments = [
            "-i", inputURL.path,
            "-v", "quiet",
            "-print_format", "json",
            "-show_streams",
            "-select_streams", "v:0"
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let json = try JSONSerialization.jsonObject(with: outputData) as? [String: Any]
        let streams = json?["streams"] as? [[String: Any]]
        guard let videoStream = streams?.first else {
            return nil
        }

        let tags = videoStream["tags"] as? [String: Any]
        let codecName = videoStream["codec_name"] as? String ?? ""
        let profile = videoStream["profile"] as? String ?? ""
        let colorTransfer = tags?["color_transfer"] as? String ?? ""
        let colorSpace = tags?["color_space"] as? String ?? ""
        let colorPrimaries = tags?["color_primaries"] as? String ?? ""

        var hdrType: HDRType?
        if profile.contains("dolby") || profile.contains("dv") || colorPrimaries.contains("smpte2086") {
            hdrType = .dolbyVision
        } else if colorTransfer == "smpte2084" || colorSpace == "bt2020nc" {
            if profile.contains("10") {
                hdrType = .hdr10Plus
            } else {
                hdrType = .hdr10
            }
        } else if colorTransfer == "arib-std-b67" {
            hdrType = .hlg
        }

        let isHDR = hdrType != nil
        let bitDepth = (videoStream["bits_per_raw_sample"] as? String ?? videoStream["bits_per_sample"] as? String ?? "8")
        let resolution = "\(videoStream["width"] as? Int ?? 0)x\(videoStream["height"] as? Int ?? 0)"

        return HDRInfo(
            isHDR: isHDR,
            hdrType: hdrType,
            codec: codecName,
            profile: profile,
            bitDepth: bitDepth,
            resolution: resolution
        )
    }
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

public enum RemuxError: Error, LocalizedError {
    case ffmpegFailed(String)
    case outputNotFound
    case ffmpegNotFound

    public var errorDescription: String? {
        switch self {
        case .ffmpegFailed(let message):
            return "ffmpeg remux failed: \(message)"
        case .outputNotFound:
            return "Remux output file not found"
        case .ffmpegNotFound:
            return "ffmpeg not found. Install via Homebrew: brew install ffmpeg"
        }
    }
}
