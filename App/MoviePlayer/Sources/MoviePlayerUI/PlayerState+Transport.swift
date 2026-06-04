@preconcurrency import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


@MainActor
extension PlayerState {
    public func togglePlayback() {
        if isFastScanning {
            stopFastScan()
            return
        }
        if userWantsPlayback {
            pause()
        } else {
            play()
        }
    }

    public func play() {
        beginPlaybackFromUserIntent(restartTorrentAtEdges: true)
    }

    public func thumbnailImage(for seconds: Double, requestID: UInt64) async -> (UInt64, NSImage?) {
        guard let service = thumbnailService else { return (requestID, nil) }
        let result = await service.thumbnail(at: seconds, requestID: requestID)
        guard let cgImage = result.image else { return (result.requestID, nil) }
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return (result.requestID, NSImage(cgImage: cgImage, size: size))
    }

    public func pause() {
        if isFastScanning {
            stopFastScan()
        }
        userWantsPlayback = false
        isPlaying = false
        isBuffering = false
        player.pause()
        publishNowPlayingIfNeeded(force: true)
    }

    public func seek(to time: Double) {
        pendingResumePosition = nil
        isApplyingResumeSeek = false
        initialSeekApplied = true
        let clamped = max(0, min(time, duration > 0 ? duration : time))

        // Pause playback and show loading state while the seek is in flight.
        player.pause()
        isPlaying = false
        isBuffering = true
        
        if isHLSTorrentPlayback, isStreamingTorrent {
            // For HLS torrent playback, TorrentPlaybackCoordinator is the single point of truth.
            pendingUserSeekTime = clamped
            Task {
                await onPrioritizeTorrentPlayback?(clamped)
                PlaybackLog.log("seek(to:) HLS Torrent triggering onRestartStreamingHLSSeek at \(clamped)")
                await onRestartStreamingHLSSeek?(clamped)
            }
        } else {
            let isTorrentPlayback = isStreamingTorrent || streamsFromLocalTorrentServer
            let isBuffered = isPlaybackTimeBuffered(clamped)
            PlaybackLog.log("seek(to:) non-HLS/local time=\(time) clamped=\(clamped) isTorrentPlayback=\(isTorrentPlayback) isBuffered=\(isBuffered)")
            if isTorrentPlayback, !isBuffered {
                pendingUserSeekTime = clamped
                Task {
                    await onPrioritizeTorrentPlayback?(clamped)
                }
            } else {
                pendingUserSeekTime = nil
            }

            if pendingUserSeekTime == nil {
                performNormalSeek(to: clamped)
            }
        }
        
        currentTime = clamped
        peakPlaybackTime = max(peakPlaybackTime, clamped)
        lastSubtitleSyncTime = -1
        updateSubtitle(at: clamped, force: true)
        publishNowPlayingIfNeeded(force: true)
        updateBufferingState()
    }

    public func performNormalSeek(to time: Double) {
        let hlsRelativeTime = time - hlsStreamTimelineOffset
        let target = CMTime(seconds: hlsRelativeTime, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let playerMovieTime = self.player.currentTime().seconds + self.hlsStreamTimelineOffset
                let atTarget = abs(playerMovieTime - time) < 1.5
                PlaybackLog.log("performNormalSeek AVPlayer seek finished=\(finished) atTarget=\(atTarget) playerMovieTime=\(playerMovieTime)")
                if finished, atTarget {
                    if self.pendingUserSeekTime == time {
                        self.pendingUserSeekTime = nil
                    }
                    self.currentTime = time
                }
                // Resume playback after the seek lands.
                if self.userWantsPlayback {
                    self.player.playImmediately(atRate: Float(self.playbackRate))
                    self.isPlaying = true
                }
                self.updateBufferingState()
            }
        }
    }

    public func seek(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    public func setVolume(_ value: Float) {
        let clamped = min(max(value, 0), Self.maxVolume)
        let wasMuted = isMuted
        volume = clamped
        if clamped > 0.001, isMuted {
            isMuted = false
            player.isMuted = false
            if wasMuted {
                PlaybackHaptics.play(.activate)
            }
        }
        applyAudioVolume()
    }

    public func toggleMute() {
        let wasMuted = isMuted
        isMuted.toggle()
        player.isMuted = isMuted
        if wasMuted, !isMuted {
            PlaybackHaptics.play(.activate)
        }
        applyAudioVolume()
    }

    func applyAudioVolume() {
        let uiVolume = isMuted ? Float(0) : volume
        audioGainController.setGain(Self.effectivePlaybackGain(for: uiVolume))
        audioGainController.updateLiveVolume(
            on: player,
            useProcessingTap: !isHLSTorrentPlayback
        )
    }

    func installAudioVolumePipeline() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.audioGainController.configure(
                for: self.player,
                useProcessingTap: !self.isHLSTorrentPlayback
            )
            self.applyAudioVolume()
        }
    }

    static func effectivePlaybackGain(for uiVolume: Float) -> Float {
        guard uiVolume > unityVolume else { return max(0, uiVolume) }
        let span = maxVolume - unityVolume
        guard span > 0 else { return unityVolume }
        let boost = (uiVolume - unityVolume) / span
        return unityVolume + boost * unityVolume
    }

    public func setPlaybackRate(_ rate: Double) {
        guard !isFastScanning else { return }
        playbackRate = rate
        if userWantsPlayback {
            player.rate = Float(rate)
        }
        presentPlaybackRateHUDPill()
    }

    public func startFastScan(forward: Bool) {
        guard isPresented else { return }

        if isFastScanning {
            // Allow live direction switching while Command is still held.
            if fastScanIsForward == forward { return }
            fastScanBackwardTask?.cancel()
        } else {
            wasPlayingBeforeFastScan = userWantsPlayback
        }

        isFastScanning = true
        fastScanIsForward = forward
        cancelHUDPillDismissTask()
        setHUDStatusPill(.fastScan(
            icon: forward ? "forward.fill" : "backward.fill",
            multiplier: 2
        ))
        fastScanBackwardTask?.cancel()
        userWantsPlayback = false
        player.pause()
        isPlaying = false
        startBackwardSeekRepeat(forward: forward)
    }

    public func stopFastScan() {
        guard isFastScanning else { return }
        cancelHUDPillDismissTask()
        isFastScanning = false
        setHUDStatusPill(nil)
        fastScanIsForward = false
        fastScanBackwardTask?.cancel()
        fastScanBackwardTask = nil
        if wasPlayingBeforeFastScan {
            beginPlaybackFromUserIntent(restartTorrentAtEdges: false)
        }
        wasPlayingBeforeFastScan = false
    }

    func startBackwardSeekRepeat(forward: Bool) {
        fastScanBackwardTask?.cancel()
        fastScanBackwardTask = Task {
            var ticks = 0
            while !Task.isCancelled {
                ticks += 1
                let multiplier = ticks >= 7 ? 4 : 2
                await MainActor.run {
                    let icon = forward ? "forward.fill" : "backward.fill"
                    self.hudStatusPill = .fastScan(icon: icon, multiplier: multiplier)
                    let delta = Double(multiplier * 6) * (forward ? 1 : -1)
                    self.seek(by: delta)
                }
                try? await Task.sleep(for: .milliseconds(220))
            }
        }
    }

    public func cyclePlaybackRate() {
        let rates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
        if let idx = rates.firstIndex(of: playbackRate) {
            let next = rates[(idx + 1) % rates.count]
            setPlaybackRate(next)
        }
    }

}
