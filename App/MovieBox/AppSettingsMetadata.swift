import CoreMetadata
import CoreStorage
import Foundation

extension AppSettings {
    /// Resolved metadata access mode from stored settings.
    var metadataMode: MetadataEndpointMode? {
        if let url = URL(string: proxyBaseURL), !proxyBaseURL.isEmpty, !appToken.isEmpty {
            return .backend(baseURL: url, appToken: appToken)
        }
        if !tmdbBearerToken.isEmpty {
            return .direct(tmdbBearerToken: tmdbBearerToken, omdbAPIKey: omdbAPIKey.isEmpty ? nil : omdbAPIKey)
        }
        return nil
    }

    var backendTorrentConfig: (baseURL: URL, appToken: String)? {
        guard let url = URL(string: proxyBaseURL), !proxyBaseURL.isEmpty, !appToken.isEmpty else {
            return nil
        }
        return (url, appToken)
    }
}
