import Foundation

/// AVPlayer / stream URL diagnostics. On by default while tuning torrent playback.
public enum PlaybackLog {
    public static let isEnabled = true

    public static func log(_ message: String) {
        guard isEnabled else { return }
        NSLog("[Playback] \(message)")
    }
}
