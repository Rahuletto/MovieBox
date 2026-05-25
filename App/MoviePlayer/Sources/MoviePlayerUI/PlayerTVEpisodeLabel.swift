import Foundation

/// HUD / Now Playing label for a TV episode (e.g. `Season 1 · Episode 3 · Pilot`).
public enum PlayerTVEpisodeLabel {
    public static func subtitle(season: Int, episode: Int, name: String) -> String {
        let base = "S\(season), E\(episode)"
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        return "\(base) · \(trimmed)"
    }
}
