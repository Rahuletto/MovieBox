import CoreStorage
import CoreStreaming
import Foundation

public enum TorrentBackendSync {
    public static func apply(from settings: AppSettings?) {
        let config = settings?.backendTorrentConfig
        TorrentMetadataFetcher.configureBackend(
            baseURL: config?.baseURL,
            appToken: config?.appToken
        )
    }
}
