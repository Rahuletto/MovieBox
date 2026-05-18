import Foundation

public actor TorrentMetadataBackend {
    public static let shared = TorrentMetadataBackend()

    private var config: TorrentMetadataFetcher.BackendConfig?

    private init() {}

    public func configure(baseURL: URL?, appToken: String?) {
        if let baseURL, let appToken, !appToken.isEmpty {
            config = TorrentMetadataFetcher.BackendConfig(
                baseURL: BackendURLSession.normalizeBaseURL(baseURL),
                appToken: appToken
            )
        } else {
            config = nil
        }
    }

    public func currentConfig() -> TorrentMetadataFetcher.BackendConfig? {
        config
    }
}
