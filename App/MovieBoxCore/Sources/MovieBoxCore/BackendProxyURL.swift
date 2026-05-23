import CoreStorage
import Foundation

/// Backend proxy endpoints (wrangler dev vs deployed Worker).
public enum BackendProxyURL {
    public static let local = "http://127.0.0.1:8787"
    public static let production = "https://moviebox-backend.rahulmarban.workers.dev"

    public static func resolved(proxyBaseURL: String, useLocalBackend: Bool) -> String {
        if useLocalBackend { return local }
        return proxyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func resolved(from settings: AppSettings) -> String {
        resolved(proxyBaseURL: settings.proxyBaseURL, useLocalBackend: settings.useLocalBackend)
    }
}
