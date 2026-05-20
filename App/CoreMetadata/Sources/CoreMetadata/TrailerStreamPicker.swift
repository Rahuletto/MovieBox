import Foundation

/// Picks a stream that AVPlayer on macOS can play (muxed MP4/HLS on allowlisted hosts — never raw video-only proxy URLs).
public enum TrailerStreamPicker {
    public struct Stream: Sendable, Equatable {
        public let url: String
        public let format: String?
        public let quality: String?
        public let videoOnly: Bool
        public let mimeType: String?

        public init(
            url: String,
            format: String? = nil,
            quality: String? = nil,
            videoOnly: Bool = true,
            mimeType: String? = nil
        ) {
            self.url = url
            self.format = format
            self.quality = quality
            self.videoOnly = videoOnly
            self.mimeType = mimeType
        }
    }

    public struct Response: Sendable {
        public let hlsUrl: String?
        public let hls: String?
        public let videoStreams: [Stream]?

        public init(hlsUrl: String? = nil, hls: String? = nil, videoStreams: [Stream]? = nil) {
            self.hlsUrl = hlsUrl
            self.hls = hls
            self.videoStreams = videoStreams
        }
    }

    public struct Selection: Sendable {
        public let url: URL
        /// Serve via localhost relay (adds Referer / Range forwarding for Piped/googlevideo proxies).
        public let needsRelay: Bool
    }

    // MARK: - Public

    public static func pickPlayable(from response: Response) -> Selection? {
        guard let stream = pickBestStream(from: response) else { return nil }
        guard let url = URL(string: stream.url) else { return nil }
        return Selection(url: url, needsRelay: needsLocalRelay(url))
    }

    public static func needsLocalRelay(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        if host.contains("odycdn") || host.contains("player.odycdn") { return false }
        if host.contains("googlevideo.com") { return true }
        if path.contains("videoplayback") { return true }
        if host.contains("proxy.piped") || host.contains("pipedproxy") { return true }
        return false
    }

    // MARK: - Picker

    private static let minimumTrailerVideoPixels = 480

    private static func pickBestStream(from response: Response) -> Stream? {
        guard let streams = response.videoStreams, !streams.isEmpty else {
            return nil
        }

        let playable = streams.filter { isCandidate($0) }
        guard !playable.isEmpty else {
            if let hls = response.hlsUrl ?? response.hls,
               !hls.isEmpty,
               isAllowlistedHost(hls),
               !hls.contains("videoplayback") {
                return Stream(url: hls, format: "HLS", quality: nil, videoOnly: false, mimeType: "application/vnd.apple.mpegurl")
            }
            return nil
        }

        let atOrAboveMin = playable.filter { streamPixelHeight($0) >= minimumTrailerVideoPixels }
        let pool = atOrAboveMin.isEmpty ? playable : atOrAboveMin

        var best: (stream: Stream, score: Int)?

        for stream in pool {
            let score = scoreStream(stream)
            if let current = best {
                if score > current.score { best = (stream, score) }
            } else {
                best = (stream, score)
            }
        }

        if let best { return best.stream }

        if let hls = response.hlsUrl ?? response.hls,
           !hls.isEmpty,
           isAllowlistedHost(hls),
           !hls.contains("videoplayback") {
            return Stream(url: hls, format: "HLS", quality: nil, videoOnly: false, mimeType: "application/vnd.apple.mpegurl")
        }

        return nil
    }

    /// Parses a best-effort video height from Piped/YouTube-style `quality` labels (e.g. `"720p"`).
    private static func streamPixelHeight(_ stream: Stream) -> Int {
        let fromLabel = parseQuality(stream.quality)
        if fromLabel > 0 { return fromLabel }
        return itagHeightHint(from: stream.url)
    }

    private static func itagHeightHint(from url: String) -> Int {
        guard let components = URLComponents(string: url),
              let items = components.queryItems,
              let raw = items.first(where: { $0.name == "itag" })?.value,
              let itag = Int(raw) else {
            return 0
        }
        switch itag {
        case 38: return 2160
        case 37: return 1080
        case 22: return 720
        case 59, 78: return 480
        case 18: return 360
        default: return 0
        }
    }

    private static func isCandidate(_ stream: Stream) -> Bool {
        let url = stream.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, URL(string: url) != nil else { return false }

        let format = stream.format?.lowercased() ?? ""
        let mime = stream.mimeType?.lowercased() ?? ""

        if format.contains("webm") || mime.contains("webm") { return false }
        if mime.contains("webm") { return false }

        // AVPlayer cannot play Piped video-only DASH-style proxy URLs (itag 137, etc.).
        if stream.videoOnly && isProxiedHost(url) { return false }

        if url.contains("odycdn") {
            return url.contains(".mp4") || url.contains("m3u8") || format.contains("hls")
        }

        if format.contains("hls") || url.contains(".m3u8") {
            return isAllowlistedHost(url)
        }

        if format.contains("mp4") || format.contains("mpeg") || mime.contains("mp4") {
            if stream.videoOnly && isProxiedHost(url) { return false }
            return !isBlockedHost(url) || !stream.videoOnly
        }

        return false
    }

    private static func scoreStream(_ stream: Stream) -> Int {
        let url = stream.url
        let format = stream.format?.lowercased() ?? ""
        var score = 0
        let quality = parseQuality(stream.quality)

        if url.contains("odycdn"), url.contains(".mp4") {
            score += 1_000
        } else if url.contains("odycdn"), (url.contains("m3u8") || format.contains("hls")) {
            score += 950
        } else if !stream.videoOnly, format.contains("mpeg") || format.contains("mp4") {
            score += 600
        } else if !stream.videoOnly {
            score += 400
        }

        if stream.videoOnly { score -= 300 }

        switch quality {
        case 720...1080: score += 50
        case 480..<720: score += 40
        case 360..<480: score += 10
        case 1081...: score += 10
        default: score += 5
        }

        score += min(quality, 1080)

        if isProxiedHost(url) { score -= 20 }

        return score
    }

    private static func parseQuality(_ raw: String?) -> Int {
        guard let raw else { return 0 }
        let digits = raw.filter(\.isNumber)
        return Int(digits) ?? 0
    }

    private static func isProxiedHost(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("videoplayback")
            || lower.contains("proxy.piped")
            || lower.contains("pipedproxy")
            || lower.contains("googlevideo.com")
    }

    private static func isBlockedHost(_ url: String) -> Bool {
        isProxiedHost(url)
    }

    private static func isAllowlistedHost(_ url: String) -> Bool {
        let lower = url.lowercased()
        if lower.contains("odycdn") { return true }
        if lower.contains("videoplayback") || lower.contains("googlevideo.com") { return false }
        return true
    }
}
