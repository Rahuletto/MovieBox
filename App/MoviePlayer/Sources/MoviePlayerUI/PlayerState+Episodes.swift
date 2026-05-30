@preconcurrency import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


@MainActor
extension PlayerState {
    public func playEpisode(at index: Int) {
        guard index >= 0 && index < episodes.count else { return }
        let ep = episodes[index]
        self.currentEpisodeIndex = index
        let episodeLabel = PlayerTVEpisodeLabel.subtitle(
            season: ep.seasonNumber,
            episode: ep.episodeNumber,
            name: ep.title
        )
        self.episodeTitle = episodeLabel

        load(
            url: ep.url,
            title: seriesName,
            movieId: movieId,
            subtitleURL: ep.subtitleURL,
            hdrType: hdrType,
            episodeTitle: episodeLabel
        )
    }

    public func playNextEpisode() {
        guard let currentIndex = currentEpisodeIndex, currentIndex + 1 < episodes.count else { return }
        let nextIndex = currentIndex + 1
        playEpisode(at: nextIndex)
    }

}
