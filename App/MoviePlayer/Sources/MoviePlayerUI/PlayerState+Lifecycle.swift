@preconcurrency import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


@MainActor
extension PlayerState {
    public func toggleFullScreen() {
        guard let window = NSApplication.shared.keyWindow else { return }
        window.toggleFullScreen(nil)
    }

    public func retryPlayback() {
        guard let last = lastPlaybackLoad else {
            PlaybackLog.log("retryPlayback skipped — no prior load")
            return
        }
        let isTorrent = last.url.host.map { $0 == "127.0.0.1" || $0 == "localhost" } ?? false
        let resume: Double? = isTorrent ? nil : (currentTime > 20 ? currentTime : last.resumePosition)
        PlaybackLog.log("retryPlayback url=\(PlaybackLog.redactURL(last.url))")
        load(
            url: last.url,
            title: last.title,
            movieId: last.movieId,
            subtitleURL: last.subtitleURL,
            hdrType: last.hdrType,
            audioFormat: last.audioFormat,
            subtitleAppearance: last.subtitleAppearance,
            subtitleFontSize: last.subtitleFontSize,
            episodeTitle: last.episodeTitle,
            episodes: last.episodes,
            currentEpisodeIndex: last.currentEpisodeIndex,
            displayTitle: last.displayTitle,
            resumePosition: resume,
            knownDurationSeconds: duration > 0 ? duration : nil,
            posterURL: last.posterURL
        )
    }

    public func dismiss() {
        if let window = NSApplication.shared.keyWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        if let prevFrame = previousWindowFrame, let window = Self.playbackHostWindow() {
            window.setFrame(prevFrame, display: true, animate: true)
            previousWindowFrame = nil
        }

        guard isPresented else { return }

        presentationTransitionTask?.cancel()
        deactivateMediaCommands()
        userWantsPlayback = false
        isPlaying = false
        isBuffering = false
        player.pause()

        withAnimation(.easeInOut(duration: 0.38)) {
            isPlayerRevealed = false
        }

        presentationTransitionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.38)) {
                isPresented = false
            }
            finalizeDismissal()
        }
    }

    func finalizeDismissal() {
        stopPlaybackResources()
        isStreamingTorrent = false
        dismissPlaybackWhenPiPCloses = false
        isPlaybackChromeHidden = false
        isPlayerRevealed = false
        isPresented = false
        currentTime = 0
        duration = 0
        trustedDurationSeconds = nil
        bufferedTimeRanges = []
        peakPlaybackTime = 0
        cachedStreamBufferRanges = []
        activeTorrentInfoHash = nil
        streamBufferTimeRangesProvider = nil
        streamPlaybackReadinessProvider = nil
        onPrioritizeTorrentPlayback = nil
        onRestartStreamingHLSSeek = nil
        isRestartingStreamingRemux = false
        hlsStreamTimelineOffset = 0
        onPersistStreamBufferRanges = nil
        pendingUserSeekTime = nil
        isApplyingPendingUserSeek = false
        lastPendingSeekRetry = .distantPast
        stopStreamBufferPolling()
        deactivateMediaCommands()
        errorMessage = nil
        episodes = []
        currentEpisodeIndex = nil
        isEpisodesSidebarOpen = false
        isSourcesSidebarOpen = false
        isSubtitlesSidebarOpen = false
        availableSubtitles = []
        selectedSubtitleID = nil
        isLoadingSubtitleCatalog = false
        subtitleLoadProgress = nil
        onSelectSubtitle = nil
        onRefreshSubtitles = nil
        onEnsureSubtitleSelected = nil
        pendingResumePosition = nil
        isApplyingResumeSeek = false
        isBuffering = false
        bufferingDetail = nil
        seriesName = ""
        episodeTitle = nil
        posterURL = nil
        hdrType = nil
        audioFormat = nil
        streamQualityDiagnostics = nil
        qualityBadgesLockedFromPrepare = false
        qualityBadgePillShownForCurrentItem = false
        playbackSources = []
        selectedPlaybackSourceID = nil
        isSwitchingSource = false
        onSelectPlaybackSource = nil
        lastPlaybackLoad = nil
        streamsFromLocalTorrentServer = false
        isHLSTorrentPlayback = false
        if let existing = thumbnailService {
            Task { await existing.clearCache() }
        }
        thumbnailService = nil
    }

    public func updatePlaybackSources(_ sources: [PlaybackSourceOption], selectedID: String?) {
        playbackSources = sources
        selectedPlaybackSourceID = selectedID
    }

    func stopPlaybackResources() {
        setHUDStatusPill(nil)
        windowAutosizeTask?.cancel()
        windowAutosizeTask = nil
        presentationTransitionTask?.cancel()
        presentationTransitionTask = nil
        isApplyingResumeSeek = false
        initialSeekApplied = false
        stopFastScan()
        stopStreamBufferPolling()
        deactivateMediaCommands()
        userWantsPlayback = false
        removeObservers()
        teardownPiP()
        cancelSubtitleWork()
        player.pause()
        player.replaceCurrentItem(with: nil)
        observedPlayerItem = nil
    }

    func cancelSubtitleWork() {
        subtitleLoadTask?.cancel()
        subtitleLoadTask = nil
        subtitleUpdateTask?.cancel()
        subtitleUpdateTask = nil
        subtitleStream = nil
        subtitleURL = nil
        activeSubtitleTrack = -1
        currentSubtitleText = ""
        currentSubtitleCueID = nil
        lastSubtitleSyncTime = -1
        subtitleLoadProgress = nil
    }

}
