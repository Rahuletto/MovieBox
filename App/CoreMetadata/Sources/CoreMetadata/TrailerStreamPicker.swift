import Foundation

/// Picks a stream URL that AVPlayer on macOS can actually play (MP4/HLS, not WebM).
enum TrailerStreamPicker {
    struct Stream: Sendable {
        let url: String
        let format: String?
        let quality: String?
    }

    struct Response: Sendable {
        let hlsUrl: String?
        let hls: String?
        let videoStreams: [Stream]?
    }

    static func pickPlayableURL(from response: Response) -> URL? {
        if let streams = response.videoStreams {
            for stream in streams {
                let url = stream.url
                let format = stream.format?.lowercased() ?? ""
                if url.contains("odycdn"), url.contains(".mp4"), !format.contains("webm"),
                   let result = URL(string: url) {
                    return result
                }
            }
        }

        if let hls = response.hlsUrl ?? response.hls,
           !hls.isEmpty,
           let url = URL(string: hls) {
            return url
        }

        guard let streams = response.videoStreams, !streams.isEmpty else { return nil }

        let candidates = streams.compactMap { stream -> (url: String, score: Int)? in
            let url = stream.url
            guard !url.isEmpty else { return nil }
            let format = stream.format?.lowercased() ?? ""
            if format.contains("webm") { return nil }

            var score = 0
            let quality = Int(stream.quality ?? "0") ?? 0

            if url.contains("odycdn"), url.contains(".mp4") {
                score += 200
            } else if format.contains("mp4") || format.contains("mpeg") {
                score += 80
            } else {
                return nil
            }

            if url.contains("proxy.piped") || url.contains("videoplayback") {
                score -= 25
            }
            if url.contains("googlevideo") {
                score -= 10
            }

            switch quality {
            case 720...1080: score += 40
            case 480..<720: score += 25
            case 360..<480: score += 15
            case 1081...: score += 5
            default: break
            }

            score += min(quality, 1080)

            return (url, score)
        }

        guard let best = candidates.max(by: { $0.score < $1.score }) else { return nil }
        return URL(string: best.url)
    }
}
