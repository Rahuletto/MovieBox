import CoreMetadata
import CoreStorage
import Foundation

public enum MetadataSettings {
    /// Prefer backend when `/health` succeeds; otherwise direct TMDB if token is stored.
    public static func resolveMode(from settings: [AppSettings]) async -> MetadataEndpointMode? {
        guard let s = settings.first else { return nil }

        let base = s.resolvedProxyBaseURL
        let token = s.appToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let tmdb = s.tmdbBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: base), !base.isEmpty, !token.isEmpty {
            if await BackendReachability.isHealthy(baseURL: url, appToken: token) {
                return .backend(baseURL: url, appToken: token)
            }
            await MainActor.run {
                LogStore.shared.log(
                    .warn,
                    category: "metadata",
                    "Worker not reachable at \(base). Open \(base)/health in Safari."
                )
            }
            if !tmdb.isEmpty {
                return .direct(tmdbBearerToken: tmdb, omdbAPIKey: s.omdbAPIKey.isEmpty ? nil : s.omdbAPIKey)
            }
            return .backend(baseURL: url, appToken: token)
        }

        if !tmdb.isEmpty {
            return .direct(tmdbBearerToken: tmdb, omdbAPIKey: s.omdbAPIKey.isEmpty ? nil : s.omdbAPIKey)
        }
        return nil
    }

    public static func mode(from settings: [AppSettings]) -> MetadataEndpointMode? {
        settings.first?.metadataMode
    }

    public static func client(from settings: [AppSettings]) -> MetadataClient? {
        guard let mode = mode(from: settings) else { return nil }
        return MetadataClient(mode: mode)
    }
}
