import CoreMetadata
import Foundation

public enum CatalogLoader {
    public static func loadRows(mode: MetadataEndpointMode, kind: MediaKind) async throws -> [MetadataCategory: [Movie]] {
        let client = MetadataClient(mode: mode)
        async let trending = client.movies(for: .trending, kind: kind)
        async let popular = client.movies(for: .popular, kind: kind)
        async let topRated = client.movies(for: .topRated, kind: kind)
        async let nowPlaying = client.movies(for: .nowPlaying, kind: kind)
        return [
            .trending: try await trending,
            .popular: try await popular,
            .topRated: try await topRated,
            .nowPlaying: try await nowPlaying,
        ]
    }

    public static func loadHomeRows(mode: MetadataEndpointMode) async throws -> [MetadataCategory: [Movie]] {
        try await loadRows(mode: mode, kind: .movie)
    }
}
