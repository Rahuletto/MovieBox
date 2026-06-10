import CoreMetadata
import CoreStorage
import Foundation

public extension AppSettings {
    /// Subtitles are fetched via the MovieBox worker (never direct TMDB).
    var subtitleServiceMode: MetadataEndpointMode? {
        let token = appToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        if useLocalBackend,
           proxyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) == BackendProxyURL.production,
           let prod = URL(string: BackendProxyURL.production) {
            return .backend(baseURL: prod, appToken: token)
        }

        let base = resolvedProxyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base), !base.isEmpty else { return nil }
        return .backend(baseURL: url, appToken: token)
    }
}
