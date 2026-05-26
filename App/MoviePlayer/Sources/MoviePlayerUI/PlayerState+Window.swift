@preconcurrency import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


@MainActor
extension PlayerState {
    func scheduleWindowAutosizeRetries() {
        guard isPresented, !hasResizedForCurrentVideo else { return }
        windowAutosizeTask?.cancel()
        windowAutosizeTask = Task { @MainActor [weak self] in
            let retryDelaysMs: [UInt64] = [0, 150, 400, 900, 1_800]
            for delay in retryDelaysMs {
                guard let self else { return }
                if self.hasResizedForCurrentVideo { return }
                if delay > 0 {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                guard !Task.isCancelled else { return }
                await self.tryAutosizeWindowToCurrentVideo()
            }
        }
    }

    func tryAutosizeWindowToCurrentVideo() async {
        guard isPresented, !hasResizedForCurrentVideo else { return }
        guard let item = observedPlayerItem else { return }
        if let size = await preferredVideoPresentationSize(for: item) {
            resizeWindowToMatch(aspectRatio: size)
        }
    }

    func preferredVideoPresentationSize(for item: AVPlayerItem) async -> CGSize? {
        let presentationSize = item.presentationSize
        if presentationSize.width > 1, presentationSize.height > 1 {
            return presentationSize
        }

        guard let tracks = try? await item.asset.loadTracks(withMediaType: .video),
              let track = tracks.first else { return nil }

        guard let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }

        let transformed = naturalSize.applying(transform)
        let width = abs(transformed.width)
        let height = abs(transformed.height)
        guard width > 1, height > 1 else { return nil }
        return CGSize(width: width, height: height)
    }

    func resizeWindowToMatch(aspectRatio: CGSize) {
        guard !hasResizedForCurrentVideo else { return }
        guard aspectRatio.width > 0, aspectRatio.height > 0 else { return }
        guard let window = Self.playbackHostWindow() else { return }

        let currentFrame = window.frame
        if previousWindowFrame == nil {
            previousWindowFrame = currentFrame
        }

        let ratio = aspectRatio.width / aspectRatio.height
        let newHeight = currentFrame.width / ratio

        hasResizedForCurrentVideo = true

        guard abs(currentFrame.height - newHeight) > 10 else { return }

        var newFrame = currentFrame
        newFrame.size.height = newHeight
        newFrame.origin.y = currentFrame.origin.y + (currentFrame.height - newHeight) / 2
        window.setFrame(newFrame, display: true, animate: true)
        PlaybackLog.log("autosized window to video aspect \(Int(aspectRatio.width))x\(Int(aspectRatio.height)) height=\(Int(newHeight))")
    }

    func removeObservers() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        playbackBufferObserver?.invalidate()
        playbackBufferObserver = nil
        playbackLikelyToKeepUpObserver?.invalidate()
        playbackLikelyToKeepUpObserver = nil
        presentationSizeObserver?.invalidate()
        presentationSizeObserver = nil
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
            self.playbackEndObserver = nil
        }
        cancellables.removeAll()
    }

}
