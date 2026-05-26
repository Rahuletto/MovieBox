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
        let clamped = max(0, min(time, duration > 0 ? duration : time))
        let isTorrentPlayback = isStreamingTorrent || streamsFromLocalTorrentServer
        if isTorrentPlayback, !isPlaybackTimeBuffered(clamped) {
            pendingUserSeekTime = clamped
            isBuffering = true
            Task {
                await onPrioritizeTorrentPlayback?(clamped)
                if isHLSTorrentPlayback, isStreamingTorrent, !isRestartingStreamingRemux {
                    await onRestartStreamingHLSSeek?(clamped)
                }
            }
        } else {
            pendingUserSeekTime = nil
        }

        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let atTarget = abs(self.player.currentTime().seconds - clamped) < 1.5
                if finished, atTarget, self.pendingUserSeekTime == clamped {
                    self.pendingUserSeekTime = nil
                }
                self.updateBufferingState()
            }
        }
        currentTime = clamped
        peakPlaybackTime = max(peakPlaybackTime, clamped)
        lastSubtitleSyncTime = -1
        updateSubtitle(at: clamped, force: true)
        publishNowPlayingIfNeeded(force: true)
        updateBufferingState()
    }

    public func seek(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    public func setVolume(_ value: Float) {
        volume = value
        player.volume = value
        if value > 0.001, isMuted {
            isMuted = false
            player.isMuted = false
        }
    }

    public func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
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
