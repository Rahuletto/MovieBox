@preconcurrency import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


@MainActor
extension PlayerState {
    func setupObservers() {
        removeObservers()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: Self.timeObserverInterval, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            let subtitleTime: Double
            if self.isApplyingResumeSeek {
                // Keep scrubber at the resume target while the seek is in flight.
                subtitleTime = self.currentTime
            } else if let userSeek = self.pendingUserSeekTime {
                subtitleTime = userSeek
                self.currentTime = userSeek
                if seconds.isFinite, seconds >= 0, abs(seconds - userSeek) < 1.5 {
                    self.pendingUserSeekTime = nil
                    self.currentTime = seconds
                    self.peakPlaybackTime = max(self.peakPlaybackTime, seconds)
                } else if self.isPlaybackTimeBuffered(userSeek) {
                    self.retryPendingUserSeekIfNeeded(target: userSeek)
                }
            } else if let pending = self.pendingResumePosition, pending > 20, seconds.isFinite, seconds < min(pending - 2, 10) {
                // Ignore head-of-file position until resume seek completes.
                subtitleTime = self.currentTime
            } else if seconds.isFinite, seconds >= 0 {
                self.currentTime = seconds
                self.peakPlaybackTime = max(self.peakPlaybackTime, seconds)
                subtitleTime = seconds
            } else {
                subtitleTime = self.currentTime
            }
            self.refreshBufferedTimeRangesFromPlayer()
            self.updateSubtitle(at: subtitleTime)
            self.publishNowPlayingIfNeeded()
            self.tryApplyPendingResume()

            guard self.movieId != 0, self.duration > 0 else { return }
            let reportedPosition = self.currentTime
            let now = Date()
            let positionDelta = abs(reportedPosition - self.lastReportedPosition)
            let elapsed = now.timeIntervalSince(self.lastPositionReportTime)
            guard elapsed >= Self.positionReportInterval || positionDelta >= Self.positionReportMinimumDelta else {
                return
            }
            self.lastPositionReportTime = now
            self.lastReportedPosition = reportedPosition
            self.onPositionUpdate?(self.movieId, reportedPosition, self.duration)
        }

        guard let currentItem = player.currentItem else { return }
        observedPlayerItem = currentItem

        let asset = currentItem.asset
        Task { [weak self] in
            guard let durationValue = try? await asset.load(.duration),
                  durationValue.isNumeric else { return }
            let seconds = durationValue.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            await MainActor.run {
                guard let self, currentItem === self.observedPlayerItem else { return }
                self.adoptDurationFromPlayer(seconds)
            }
        }

        itemStatusObserver = currentItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, item === self.observedPlayerItem else { return }
                switch item.status {
                case .failed:
                    let message = Self.playbackFailureMessage(from: item.error)
                    PlaybackLog.log("AVPlayerItem failed: \(message)")
                    self.errorMessage = message
                    self.isBuffering = false
                    self.userWantsPlayback = false
                    self.isPlaying = false
                    self.player.pause()
                    self.publishNowPlayingIfNeeded(force: true)
                case .readyToPlay:
                    let readyDuration = item.asset.duration.seconds
                    if readyDuration.isFinite, readyDuration > 0 {
                        self.adoptDurationFromPlayer(readyDuration)
                    }
                    PlaybackLog.log("AVPlayerItem readyToPlay duration=\(self.duration)s")
                    // #region agent log
                    if let container = self.pipHostView {
                        let superName = container.superview.map { String(describing: type(of: $0)) } ?? "nil"
                        DebugAgentLog.write(
                            hypothesisId: "H1,H2,H4",
                            location: "CorePlayer.swift:readyToPlay",
                            message: "item ready",
                            data: [
                                "duration": String(self.duration),
                                "containerFrame": NSStringFromRect( container.frame),
                                "layerFrame": NSStringFromRect( container.playerLayer.frame),
                                "superview": superName,
                                "pendingResume": self.pendingResumePosition.map { String($0) } ?? "nil",
                            ]
                        )
                    }
                    // #endregion
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.applyStreamQualityBadgesFromAsset(item: item)
                    }
                    self.errorMessage = nil
                    self.bufferingDetail = nil
                    self.tryApplyPendingResume()
                    self.updateBufferingState(for: item)
                    self.scheduleWindowAutosizeRetries()
                    Task { @MainActor [weak self] in
                        guard let self, item === self.observedPlayerItem else { return }
                        let tracks = await self.discoverEmbeddedLegibleTracks()
                        guard !tracks.isEmpty else { return }
                        self.onEmbeddedLegibleTracksDiscovered?(tracks)
                    }
                case .unknown:
                    PlaybackLog.log("AVPlayerItem status=unknown (buffering)")
                    self.updateBufferingState(for: item)
                @unknown default:
                    break
                }
            }
        }

        playbackBufferObserver = currentItem.observe(\.isPlaybackBufferEmpty, options: [.new, .initial]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, item === self.observedPlayerItem else { return }
                self.updateBufferingState(for: item)
            }
        }

        playbackLikelyToKeepUpObserver = currentItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, item === self.observedPlayerItem else { return }
                self.updateBufferingState(for: item)
                if item.isPlaybackLikelyToKeepUp {
                    self.nudgePlaybackIfStalled()
                }
            }
        }

        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: currentItem,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let currentIndex = self.currentEpisodeIndex, currentIndex + 1 < self.episodes.count {
                    self.playNextEpisode()
                } else {
                    self.userWantsPlayback = false
                    self.isPlaying = false
                    self.publishNowPlayingIfNeeded(force: true)
                }
            }
        }

        presentationSizeObserver = currentItem.observe(\.presentationSize, options: [.new, .initial]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, item === self.observedPlayerItem else { return }
                let size = item.presentationSize
                guard size.width > 1, size.height > 1 else { return }
                self.resizeWindowToMatch(aspectRatio: size)
            }
        }

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if status == .waitingToPlayAtSpecifiedRate,
                       let reason = self.player.reasonForWaitingToPlay {
                        PlaybackLog.log("waitingToPlay reason=\(reason.rawValue) wantsPlay=\(self.userWantsPlayback)")
                    } else if status == .playing {
                        if !self.isPlaying { self.isPlaying = true }
                        PlaybackLog.log("timeControlStatus=playing wantsPlay=\(self.userWantsPlayback)")
                    } else if status == .paused {
                        if self.isPictureInPictureActive {
                            if self.isPlaying { self.isPlaying = false }
                            self.updateBufferingState()
                            return
                        }
                        if self.userWantsPlayback {
                            PlaybackLog.log("timeControlStatus=paused but user wants play — nudging")
                            self.nudgePlaybackIfStalled()
                        } else if self.isPlaying {
                            self.isPlaying = false
                        }
                    }
                    self.updateBufferingState()
                }
            }
            .store(in: &cancellables)
    }

    func tryApplyPendingResume() {
        guard isPresented, userWantsPlayback else { return }
        guard let resumeItem = observedPlayerItem, resumeItem.status == .readyToPlay else { return }
        guard !isApplyingResumeSeek else { return }

        if let resume = pendingResumePosition, resume > 20 {
            if (streamsFromLocalTorrentServer || isStreamingTorrent), !isResumePositionBuffered(resume) { return }

            isApplyingResumeSeek = true
            pendingResumePosition = nil
            isBuffering = true
            player.pause()

            let target = CMTime(seconds: resume, preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard resumeItem === self.observedPlayerItem else {
                        self.isApplyingResumeSeek = false
                        return
                    }
                    self.isApplyingResumeSeek = false
                    guard finished else {
                        self.pendingResumePosition = resume
                        self.updateBufferingState()
                        return
                    }
                    self.currentTime = resume
                    self.peakPlaybackTime = max(self.peakPlaybackTime, resume)
                    self.lastSubtitleSyncTime = -1
                    self.updateSubtitle(at: resume, force: true)
                    PlaybackLog.log("resume at \(Int(resume))s before playback")
                    if self.userWantsPlayback {
                        self.player.playImmediately(atRate: Float(self.playbackRate))
                        self.isBuffering = false
                        self.updateBufferingState()
                        self.publishNowPlayingIfNeeded(force: true)
                    }
                }
            }
        } else if (streamsFromLocalTorrentServer || isStreamingTorrent), !initialSeekApplied {
            initialSeekApplied = true
            isApplyingResumeSeek = true
            isBuffering = true
            player.pause()

            let target = CMTime.zero
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard resumeItem === self.observedPlayerItem else {
                        self.isApplyingResumeSeek = false
                        return
                    }
                    self.isApplyingResumeSeek = false
                    self.currentTime = 0
                    self.peakPlaybackTime = 0
                    self.lastSubtitleSyncTime = -1
                    self.updateSubtitle(at: 0, force: true)
                    PlaybackLog.log("force initial seek to 0s to prevent HLS live-edge offset")
                    if self.userWantsPlayback {
                        self.player.playImmediately(atRate: Float(self.playbackRate))
                        self.isBuffering = false
                        self.updateBufferingState()
                        self.publishNowPlayingIfNeeded(force: true)
                    }
                }
            }
        }
    }

    func isPlaybackTimeBuffered(_ seconds: Double) -> Bool {
        isResumePositionBuffered(seconds, allowPlayedThrough: true)
    }

    /// Stricter check for continue-watching seeks — requires real byte ranges, not UI-only peak time.
    func isResumePositionBuffered(_ seconds: Double, allowPlayedThrough: Bool = false) -> Bool {
        if seconds < 45 { return true }
        if isStreamingTorrent || streamsFromLocalTorrentServer {
            for range in cachedStreamBufferRanges {
                if range.contains(seconds) { return true }
            }
            if allowPlayedThrough, seconds <= peakPlaybackTime + 2 { return true }
        }
        guard let item = observedPlayerItem else { return false }
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = CMTimeGetSeconds(range.start)
            let end = start + CMTimeGetSeconds(range.duration)
            guard start.isFinite, end.isFinite, end > start else { continue }
            if seconds >= start - 1, seconds < end { return true }
        }
        return false
    }

    func shouldRestartTorrentStreamFromBeginning() -> Bool {
        if pendingResumePosition != nil || isApplyingResumeSeek { return false }
        let t = currentTime
        if !t.isFinite || t < 1 { return true }
        if duration > 0, t >= max(0, duration - 3) { return true }
        if observedPlayerItem?.status == .failed { return true }
        return false
    }

    func updateBufferingState(for item: AVPlayerItem? = nil) {
        let item = item ?? observedPlayerItem

        if !isPresented || errorMessage != nil {
            isBuffering = false
            return
        }

        if isSwitchingSource {
            isBuffering = true
            return
        }

        guard let item else {
            isBuffering = true
            return
        }

        if item.status == .failed {
            isBuffering = false
            return
        }

        if item.status != .readyToPlay {
            isBuffering = true
            return
        }

        if player.timeControlStatus == .playing {
            isBuffering = false
            return
        }

        if player.timeControlStatus == .paused {
            if userWantsPlayback,
               pendingResumePosition != nil || pendingUserSeekTime != nil
               || isApplyingResumeSeek || isApplyingPendingUserSeek
               || !isPlaybackTimeBuffered(currentTime) {
                isBuffering = true
            } else {
                isBuffering = false
            }
            return
        }

        if !userWantsPlayback {
            isBuffering = false
            return
        }

        // Torrent/custom streams often keep isPlaybackLikelyToKeepUp false after pause/resume
        // even when the byte ranges we track (and AVPlayer's loaded ranges) already cover t.
        if isPlaybackTimeBuffered(currentTime) {
            isBuffering = false
            return
        }

        if item.isPlaybackLikelyToKeepUp {
            isBuffering = false
            return
        }

        isBuffering = true
    }

    /// AVPlayer can stay `.paused` after `play()` on torrent streams — retry without fighting user intent.
    func nudgePlaybackIfStalled() {
        guard userWantsPlayback else { return }
        guard pendingResumePosition == nil, pendingUserSeekTime == nil,
              !isApplyingResumeSeek, !isApplyingPendingUserSeek else { return }
        guard isPresented, errorMessage == nil, !isSwitchingSource, !isFastScanning else { return }
        guard player.timeControlStatus != .playing else { return }
        guard let item = observedPlayerItem, item.status == .readyToPlay else { return }

        let canResume = item.isPlaybackLikelyToKeepUp || isPlaybackTimeBuffered(currentTime)
        guard canResume else { return }

        let now = Date()
        guard now.timeIntervalSince(lastPlaybackResumeAttempt) >= 0.35 else { return }
        lastPlaybackResumeAttempt = now

        if playbackRate <= 0 {
            playbackRate = 1.0
        }
        player.playImmediately(atRate: Float(playbackRate))
        PlaybackLog.log("nudgePlaybackIfStalled at \(Int(currentTime))s")
    }

    public func refreshBufferedTimeRangesFromPlayer() {
        var ranges: [ClosedRange<Double>] = []
        if let item = player.currentItem {
            ranges = item.loadedTimeRanges.compactMap { value in
                let range = value.timeRangeValue
                let start = CMTimeGetSeconds(range.start)
                let end = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
                guard start.isFinite, end.isFinite, end > start else { return nil }
                return start...end
            }
        }
        if !isHLSTorrentPlayback, !cachedStreamBufferRanges.isEmpty {
            ranges.append(contentsOf: cachedStreamBufferRanges)
        }
        bufferedTimeRanges = Self.mergeTimeRanges(ranges)
    }

    static func mergeTimeRanges(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        var current = sorted[0]
        for range in sorted.dropFirst() {
            if range.lowerBound <= current.upperBound + 0.25 {
                current = current.lowerBound...max(current.upperBound, range.upperBound)
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)
        return merged
    }

    func startStreamBufferPolling() {
        guard streamBufferTimeRangesProvider != nil else { return }
        streamBufferPollTask?.cancel()
        streamBufferPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let provider = self.streamBufferTimeRangesProvider else { return }
                let ranges = await provider()
                guard !Task.isCancelled else { return }
                self.cachedStreamBufferRanges = ranges
                self.refreshBufferedTimeRangesFromPlayer()
                if let hash = self.activeTorrentInfoHash,
                   self.movieId > 0,
                   self.duration.isFinite,
                   self.duration > 0,
                   !ranges.isEmpty {
                    self.onPersistStreamBufferRanges?(
                        self.movieId,
                        hash,
                        self.duration,
                        ranges
                    )
                }
                self.updateBufferingState()
                self.tryApplyPendingResume()
                if let pendingSeek = self.pendingUserSeekTime {
                    await self.onPrioritizeTorrentPlayback?(pendingSeek)
                    self.retryPendingUserSeekIfNeeded(target: pendingSeek)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stopStreamBufferPolling() {
        streamBufferPollTask?.cancel()
        streamBufferPollTask = nil
    }

    /// Re-issue AVPlayer seek once torrent bytes at `target` are readable (scrubber-driven, not sequential).
    func retryPendingUserSeekIfNeeded(target: Double) {
        guard let pending = pendingUserSeekTime, abs(pending - target) < 0.5 else { return }
        guard isStreamingTorrent || streamsFromLocalTorrentServer else { return }
        guard isPlaybackTimeBuffered(target) else { return }
        guard let item = observedPlayerItem, item.status == .readyToPlay else { return }
        guard !isApplyingResumeSeek, !isApplyingPendingUserSeek else { return }

        let playerSeconds = player.currentTime().seconds
        guard playerSeconds.isFinite else { return }
        if abs(playerSeconds - target) < 1.5 {
            pendingUserSeekTime = nil
            currentTime = target
            peakPlaybackTime = max(peakPlaybackTime, target)
            updateBufferingState()
            if userWantsPlayback, player.timeControlStatus != .playing {
                nudgePlaybackIfStalled()
            }
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastPendingSeekRetry) >= 0.4 else { return }
        lastPendingSeekRetry = now
        isApplyingPendingUserSeek = true
        isBuffering = true

        let resumePlaying = userWantsPlayback
        if resumePlaying {
            player.pause()
        }

        let seekTarget = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: seekTarget, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isApplyingPendingUserSeek = false
                let atTarget = abs(self.player.currentTime().seconds - target) < 1.5
                if finished, atTarget {
                    self.pendingUserSeekTime = nil
                    self.currentTime = target
                    self.peakPlaybackTime = max(self.peakPlaybackTime, target)
                    self.lastSubtitleSyncTime = -1
                    self.updateSubtitle(at: target, force: true)
                    if resumePlaying, self.userWantsPlayback {
                        self.player.playImmediately(atRate: Float(self.playbackRate))
                    }
                }
                self.updateBufferingState()
            }
        }
    }

}
