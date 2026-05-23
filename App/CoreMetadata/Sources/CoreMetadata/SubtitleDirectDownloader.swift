import Foundation

/// Downloads subtitle files on the Mac. SubDL and subf2m CDNs block Cloudflare Worker egress.
enum SubtitleDirectDownloader {
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

    static func shouldDownloadDirectly(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.hasPrefix("/subtitles/") || lower.contains("subf2m.co") { return true }
        if lower.contains("dl.subdl.com") || lower.contains("isubcdn.com") { return true }
        if lower.hasPrefix("/subtitle/") { return true }
        return false
    }

    static func download(path: String, session: URLSession = .shared) async throws -> Data {
        if isSubf2mPath(path) {
            return try await downloadSubf2m(path: path, session: session)
        }
        return try await downloadSubdlCDN(path: path, session: session)
    }

    private static func isSubf2mPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasPrefix("/subtitles/") || lower.contains("subf2m.co")
    }

    private static func downloadSubf2m(path: String, session: URLSession) async throws -> Data {
        let detailURL = try subf2mDetailPageURL(for: path)
        let downloadURL = detailURL.path.hasSuffix("/download")
            ? detailURL
            : detailURL.appendingPathComponent("download")

        var request = URLRequest(url: downloadURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(detailURL.absoluteString, forHTTPHeaderField: "Referer")
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)
        return try normalizeSubtitlePayload(data)
    }

    /// SubDL CDN: `https://dl.subdl.com/subtitle/{id}.zip` or `.../subtitle/{n_id}/{file_n_id}`.
    private static func downloadSubdlCDN(path: String, session: URLSession) async throws -> Data {
        let downloadURL = try subdlCDNURL(for: path)

        var request = URLRequest(url: downloadURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://subdl.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)
        return try normalizeSubtitlePayload(data)
    }

    private static func subf2mDetailPageURL(for path: String) throws -> URL {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            guard let url = URL(string: path) else { throw SubtitleError.invalidURL }
            guard let host = url.host?.lowercased(), host.contains("subf2m.co") else {
                throw SubtitleError.invalidURL
            }
            return url
        }
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: "https://subf2m.co\(normalized)") else {
            throw SubtitleError.invalidURL
        }
        return url
    }

    private static func subdlCDNURL(for path: String) throws -> URL {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            guard let url = URL(string: path) else { throw SubtitleError.invalidURL }
            guard let host = url.host?.lowercased(),
                  host.contains("dl.subdl.com") || host.contains("isubcdn.com")
            else {
                throw SubtitleError.invalidURL
            }
            return url
        }
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: "https://dl.subdl.com\(normalized)") else {
            throw SubtitleError.invalidURL
        }
        return url
    }

    private static func validateHTTP(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SubtitleError.upstream(
                status: http.statusCode,
                message: "Subtitle download returned HTTP \(http.statusCode)."
            )
        }
    }

    private static func normalizeSubtitlePayload(_ data: Data) throws -> Data {
        if data.starts(with: [0x50, 0x4B]) {
            return try SubtitleArchiveExtractor.extractSRT(from: data)
        }
        if SubtitlePayloadValidator.looksLikeSRT(data) {
            return data
        }
        throw SubtitleError.invalidPayload
    }
}
