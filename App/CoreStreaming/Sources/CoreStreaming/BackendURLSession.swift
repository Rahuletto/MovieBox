import Foundation

/// URLSession that bypasses system HTTP proxies (PAC/VPN) for local MovieBox backend calls.
enum BackendURLSession {
    static let direct: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    static func normalizeBaseURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url
        }
        if components.host?.lowercased() == "localhost" {
            components.host = "127.0.0.1"
        }
        return components.url ?? url
    }

    static func metadataURL(baseURL: URL, infoHash: String) -> URL? {
        let base = normalizeBaseURL(baseURL)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: true)
        let path = components?.path ?? ""
        let prefix = path.hasSuffix("/") ? String(path.dropLast()) : path
        components?.path = "\(prefix)/api/torrent/metadata"
        components?.queryItems = [URLQueryItem(name: "hash", value: infoHash.lowercased())]
        return components?.url
    }
}
