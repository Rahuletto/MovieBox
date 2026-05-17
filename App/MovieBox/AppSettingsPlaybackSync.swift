import CorePlayer
import CoreStorage
import SwiftData
import SwiftUI

/// Pushes SwiftData playback settings into the active player as they change.
struct AppSettingsPlaybackSync: View {
    @Environment(PlayerState.self) private var playerState
    @Query private var settings: [AppSettings]

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear(perform: sync)
            .onChange(of: settings.first?.subtitleStyle) { _, _ in sync() }
            .onChange(of: settings.first?.subtitlesEnabled) { _, _ in sync() }
    }

    private func sync() {
        guard let settings = settings.first else { return }
        playerState.applyPlaybackSettings(
            subtitleStyle: settings.subtitleStyle,
            subtitlesEnabled: settings.subtitlesEnabled
        )
    }
}
