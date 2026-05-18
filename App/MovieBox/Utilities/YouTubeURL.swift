import Foundation

enum YouTubeURL {
    static func embedURL(for videoURL: URL) -> URL? {
        guard let key = parseKey(from: videoURL) else { return videoURL }
        return URL(string: "https://www.youtube.com/embed/\(key)?autoplay=1&rel=0&modestbranding=1&playsinline=1&enablejsapi=1")
    }

    static func parseKey(from url: URL) -> String? {
        let absoluteString = url.absoluteString
        if absoluteString.contains("youtube.com/embed/") {
            return absoluteString
                .components(separatedBy: "youtube.com/embed/")
                .last?
                .components(separatedBy: "?")
                .first
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems,
           let key = queryItems.first(where: { $0.name == "v" })?.value {
            return key
        }
        if absoluteString.contains("youtu.be/") {
            return absoluteString
                .components(separatedBy: "youtu.be/")
                .last?
                .components(separatedBy: "?")
                .first
        }
        return nil
    }
}
