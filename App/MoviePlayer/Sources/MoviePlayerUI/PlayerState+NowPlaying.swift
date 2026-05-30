@preconcurrency import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


@MainActor
extension PlayerState {
    func activateMediaCommands() {
        if mediaCommandCenter == nil {
            mediaCommandCenter = PlayerMediaCommandCenter(state: self)
        }
        mediaCommandCenter?.activate()
        if let payload = makeNowPlayingPayload() {
            mediaCommandCenter?.publish(payload)
        }
    }

    func deactivateMediaCommands() {
        mediaCommandCenter?.deactivate()
        mediaCommandCenter = nil
        lastNowPlayingPublishTime = .distantPast
    }

    /// Rate reported to Control Center — only `.playing` when AVPlayer is actually playing.
    var nowPlayingPlaybackRate: Double {
        guard userWantsPlayback else { return 0 }
        return player.timeControlStatus == .playing ? playbackRate : 0
    }

    func makeNowPlayingPayload() -> NowPlayingPublishPayload? {
        let label = episodeTitle ?? seriesName
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let duration = max(0, duration)
        let position = max(0, min(currentTime, duration > 0 ? duration : currentTime))
        let albumTitle: String? = {
            guard let episode = episodeTitle, !episode.isEmpty else { return nil }
            return seriesName
        }()

        return NowPlayingPublishPayload(
            title: trimmed,
            albumTitle: albumTitle,
            duration: duration,
            position: position,
            rate: nowPlayingPlaybackRate,
            posterURL: posterURL
        )
    }

    func publishNowPlayingIfNeeded(force: Bool = false) {
        guard isPresented else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastNowPlayingPublishTime) < 0.9 { return }
        lastNowPlayingPublishTime = now
        guard let payload = makeNowPlayingPayload() else { return }
        mediaCommandCenter?.publish(payload)
    }

    static func playbackHostWindow() -> NSWindow? {
        for candidate in [NSApp.keyWindow, NSApp.mainWindow] {
            if let window = candidate, window.isVisible, !window.styleMask.contains(.fullScreen) {
                return window
            }
        }
        return NSApp.windows.first { window in
            window.isVisible
                && !window.styleMask.contains(.fullScreen)
                && !(window is NSPanel)
        }
    }

}
