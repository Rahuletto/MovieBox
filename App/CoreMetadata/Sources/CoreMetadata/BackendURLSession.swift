import Foundation

/// Ephemeral session with an empty proxy dictionary (same pattern as CoreStreaming).
/// Avoids broken system PAC/proxy entries that surface as TLS or CFNetwork 310 errors.
public enum BackendURLSession {
    public static let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()
}
