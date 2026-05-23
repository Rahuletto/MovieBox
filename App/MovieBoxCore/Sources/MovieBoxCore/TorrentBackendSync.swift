import CoreStorage
import CoreStreaming
import Foundation

public enum TorrentBackendSync {
    /// Fixes a common dev misconfiguration where production URL is stored but traffic still goes to localhost.
    @discardableResult
    public static func repairProxySettings(_ settings: AppSettings) -> Bool {
        let proxy = settings.proxyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.useLocalBackend, proxy == BackendProxyURL.production else { return false }
        settings.useLocalBackend = false
        return true
    }

    public static func apply(from settings: AppSettings?) {
        let config = settings?.backendTorrentConfig
        TorrentMetadataFetcher.configureBackend(
            baseURL: config?.baseURL,
            appToken: config?.appToken
        )
    }
}
