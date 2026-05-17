// Demos disabled — see StreamTestCatalog.swift
#if false

import CorePlayer
import CoreStorage
import Foundation

enum DemoPlayback {
    @MainActor
    static func play(
        _ item: StreamTestCatalog.Item,
        playerState: PlayerState,
        settings: AppSettings?
    ) {
        let appearance = SubtitleAppearance.from(settingsValue: settings?.subtitleStyle ?? "cinematic")
        let fontSize = CGFloat(settings?.subtitleFontSize ?? 20)

        if item.isSubtitleDemo {
            guard let subtitleURL = StreamTestCatalog.bundledSubtitle else { return }
            playerState.load(
                url: item.url,
                title: item.title,
                movieId: 0,
                subtitleURL: subtitleURL,
                hdrType: item.hdrType,
                subtitleAppearance: appearance,
                subtitleFontSize: fontSize
            )
        } else {
            playerState.load(
                url: item.url,
                title: item.title,
                movieId: 0,
                subtitleURL: nil,
                hdrType: item.hdrType,
                subtitleAppearance: appearance,
                subtitleFontSize: fontSize
            )
        }
    }
}

#endif
