import CoreMetadata
import CorePlayer
import CoreStorage
import CoreTorrent
import Foundation

public extension AppSettings {
    var resolvedProxyBaseURL: String {
        BackendProxyURL.resolved(from: self)
    }

    /// Resolved metadata access mode from stored settings.
    var metadataMode: MetadataEndpointMode? {
        let base = resolvedProxyBaseURL
        let token = appToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: base), !base.isEmpty, !token.isEmpty {
            return .backend(baseURL: url, appToken: token)
        }
        if !tmdbBearerToken.isEmpty {
            return .direct(tmdbBearerToken: tmdbBearerToken, omdbAPIKey: omdbAPIKey.isEmpty ? nil : omdbAPIKey)
        }
        return nil
    }

    var backendTorrentConfig: (baseURL: URL, appToken: String)? {
        let base = resolvedProxyBaseURL
        let token = appToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base), !base.isEmpty, !token.isEmpty else {
            return nil
        }
        return (url, token)
    }

    var subtitleAppearance: SubtitleAppearance {
        SubtitleAppearance.from(settingsValue: subtitleStyle)
    }

    var subtitleFontSizePoints: CGFloat {
        CGFloat(subtitleFontSize > 0 ? subtitleFontSize : 20)
    }

    @MainActor
    func applyLivePlaybackSettings(to playerState: PlayerState) {
        playerState.applyPlaybackSettings(
            subtitleStyle: subtitleStyle,
            subtitlesEnabled: subtitlesEnabled,
            subtitleFontSize: subtitleFontSize
        )
    }

    var enabledTorrentIndexerSet: Set<String> {
        let parsed = TorrentIndexerPreferences.parseCSV(enabledTorrentIndexers)
        if parsed.isEmpty { return TorrentIndexerPreferences.defaultIDs }
        // Upgrade installs still on the old five-indexer default.
        let legacyDefault: Set<String> = ["torrentio", "yts", "eztv", "piratebay", "1337x"]
        if parsed == legacyDefault {
            return TorrentIndexerPreferences.defaultIDs
        }
        return parsed
    }

    var cacheKey: String {
        "\(useLocalBackend)|\(resolvedProxyBaseURL)|\(appToken)|\(tmdbBearerToken)|\(posterSize)|\(backdropSize)|\(requestTimeout)"
    }
}
