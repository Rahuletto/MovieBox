import CoreMetadata
import CorePlayer
import CoreStorage
import CoreTorrent
import Foundation

public extension AppSettings {
    /// Resolved metadata access mode from stored settings.
    var metadataMode: MetadataEndpointMode? {
        let base = proxyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let base = proxyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if !enabledTorrentIndexers.isEmpty { return parsed }
        var ids = parsed
        if !enableYTS { ids.remove("yts") }
        return ids
    }

    var cacheKey: String {
        "\(proxyBaseURL)|\(appToken)|\(tmdbBearerToken)|\(posterSize)|\(backdropSize)|\(requestTimeout)"
    }
}
