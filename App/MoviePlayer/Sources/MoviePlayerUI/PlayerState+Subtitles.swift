@preconcurrency import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


@MainActor
extension PlayerState {
    public func applyPlaybackSettings(
        subtitleStyle: String,
        subtitlesEnabled: Bool,
        subtitleFontSize: Double = 20
    ) {
        subtitleAppearance = SubtitleAppearance.from(settingsValue: subtitleStyle)
        self.subtitleFontSize = CGFloat(subtitleFontSize)

        if !subtitlesEnabled {
            if activeSubtitleTrack >= 0 {
                activeSubtitleTrack = -1
                currentSubtitleText = ""
                currentSubtitleCueID = nil
            }
            clearEmbeddedLegibleSelection()
            return
        }

        if usesAVPlayerEmbeddedSubtitles {
            if activeSubtitleTrack < 0,
               let group = legibleSelectionGroup,
               let first = group.options.first,
               let item = player.currentItem {
                item.select(first, in: group)
                activeSubtitleTrack = 0
            }
            return
        }

        guard subtitleURL != nil else { return }

        if subtitleStream != nil {
            if activeSubtitleTrack < 0 {
                activeSubtitleTrack = 0
            }
            updateSubtitle(at: currentTime, force: true)
        } else if let url = subtitleURL {
            loadSubtitleStream(from: url)
        }
    }

    func disableEmbeddedCaptions(on playerItem: AVPlayerItem, asset: AVURLAsset) {
        Task { [weak self] in
            guard let group = try? await asset.loadMediaSelectionGroup(for: .legible) else { return }
            await MainActor.run { [weak self] in
                guard let self, playerItem === self.observedPlayerItem else { return }
                playerItem.select(nil, in: group)
            }
        }
    }

    public func setSubtitleLoadProgress(_ progress: SubtitleLoadProgress?) {
        subtitleLoadProgress = progress
    }

    public var showsCustomSubtitleOverlay: Bool {
        activeSubtitleTrack >= 0 && !usesAVPlayerEmbeddedSubtitles
    }

    public func discoverEmbeddedLegibleTracks() async -> [EmbeddedLegibleTrack] {
        guard let item = player.currentItem else {
            legibleSelectionGroup = nil
            return []
        }
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              !group.options.isEmpty else {
            legibleSelectionGroup = nil
            return []
        }
        legibleSelectionGroup = group
        return group.options.enumerated().map { index, option in
            let language =
                option.locale?.identifier
                ?? option.extendedLanguageTag
                ?? "unknown"
            return EmbeddedLegibleTrack(
                index: index,
                displayName: option.displayName,
                language: language
            )
        }
    }

    public func selectEmbeddedLegibleTrack(at index: Int) {
        guard let group = legibleSelectionGroup,
              let item = player.currentItem,
              index >= 0,
              index < group.options.count else { return }

        subtitleLoadTask?.cancel()
        subtitleStream = nil
        usesAVPlayerEmbeddedSubtitles = true
        item.select(group.options[index], in: group)
        activeSubtitleTrack = index
        currentSubtitleText = ""
        currentSubtitleCueID = nil
        setSubtitleLoadProgress(nil)
    }

    public func clearEmbeddedLegibleSelection() {
        guard let group = legibleSelectionGroup, let item = player.currentItem else {
            usesAVPlayerEmbeddedSubtitles = false
            return
        }
        item.select(nil, in: group)
        usesAVPlayerEmbeddedSubtitles = false
    }

    public func loadSubtitleStream(from url: URL) {
        clearEmbeddedLegibleSelection()
        subtitleURL = url
        subtitleLoadTask?.cancel()
        subtitleUpdateTask?.cancel()
        subtitleStream = nil
        let fileLabel = url.deletingPathExtension().lastPathComponent
        setSubtitleLoadProgress(SubtitleLoadProgress(title: "Loading subtitle file", detail: fileLabel))
        subtitleLoadTask = Task { @MainActor in
            defer { setSubtitleLoadProgress(nil) }
            do {
                setSubtitleLoadProgress(
                    SubtitleLoadProgress(title: "Reading subtitle file", detail: fileLabel)
                )
                let data: Data
                if url.isFileURL {
                    data = try Data(contentsOf: url)
                } else {
                    (data, _) = try await URLSession.shared.data(from: url)
                }
                guard !Task.isCancelled else { return }
                setSubtitleLoadProgress(
                    SubtitleLoadProgress(title: "Parsing subtitles", detail: fileLabel)
                )
                let stream = SubtitleStream()
                await stream.load(from: data)
                guard !Task.isCancelled else { return }
                let cueCount = await stream.totalCues
                guard cueCount > 0 else {
                    NSLog("Subtitle file has no cues: \(url.lastPathComponent)")
                    setSubtitleLoadProgress(
                        SubtitleLoadProgress(title: "No cues in subtitle file", detail: fileLabel)
                    )
                    try? await Task.sleep(for: .seconds(2.5))
                    return
                }
                subtitleStream = stream
                activeSubtitleTrack = 0
                lastSubtitleSyncTime = -1
                updateSubtitle(at: currentTime, force: true)
                NSLog("Loaded \(cueCount) subtitle cues from \(url.lastPathComponent)")
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("Failed to load subtitle stream: \(error)")
                setSubtitleLoadProgress(
                    SubtitleLoadProgress(
                        title: "Couldn't load subtitles",
                        detail: (error as NSError).localizedDescription
                    )
                )
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    public func toggleSubtitle() {
        setSubtitlesEnabled(activeSubtitleTrack < 0)
    }

    public func setSubtitlesEnabled(_ enabled: Bool) {
        if enabled {
            activeSubtitleTrack = 0
            currentSubtitleText = ""
            currentSubtitleCueID = nil

            if let url = subtitleURL {
                if subtitleStream == nil {
                    loadSubtitleStream(from: url)
                } else {
                    updateSubtitle(at: currentTime, force: true)
                }
                return
            }

            Task { @MainActor in
                setSubtitleLoadProgress(SubtitleLoadProgress(title: "Finding subtitles", detail: nil))
                await onEnsureSubtitleSelected?()
                guard subtitleURL != nil else {
                    if subtitleStream == nil {
                        activeSubtitleTrack = -1
                        setSubtitleLoadProgress(
                            SubtitleLoadProgress(title: "No subtitle available", detail: "Pick a track from the list")
                        )
                        try? await Task.sleep(for: .seconds(2.5))
                        setSubtitleLoadProgress(nil)
                    }
                    return
                }
                if subtitleStream == nil, let url = subtitleURL {
                    loadSubtitleStream(from: url)
                } else {
                    activeSubtitleTrack = 0
                    updateSubtitle(at: currentTime, force: true)
                }
            }
        } else {
            activeSubtitleTrack = -1
            currentSubtitleText = ""
            currentSubtitleCueID = nil
            setSubtitleLoadProgress(nil)
        }
    }

    public var areSubtitlesEnabled: Bool {
        activeSubtitleTrack >= 0
    }

    /// Subtitles sidebar can open when catalog handlers or embedded tracks exist.
    public var canOpenSubtitlesSidebar: Bool {
        onSelectSubtitle != nil || onRefreshSubtitles != nil || !availableSubtitles.isEmpty
    }

    public func updateSubtitle(at time: TimeInterval, force: Bool = false) {
        guard activeSubtitleTrack >= 0, let stream = subtitleStream else {
            if !currentSubtitleText.isEmpty {
                currentSubtitleText = ""
                currentSubtitleCueID = nil
            }
            return
        }

        if !force, abs(time - lastSubtitleSyncTime) < Self.subtitleSyncInterval {
            return
        }
        lastSubtitleSyncTime = time

        subtitleUpdateTask?.cancel()
        subtitleUpdateTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            if let cue = await stream.cue(at: time) {
                if !Task.isCancelled {
                    currentSubtitleCueID = cue.id
                    currentSubtitleText = cue.text
                }
            } else if !Task.isCancelled {
                currentSubtitleText = ""
                currentSubtitleCueID = nil
            }
        }
    }

}
