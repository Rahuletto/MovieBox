@preconcurrency import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


@MainActor
extension PlayerState {
    private enum WindowAutosize {
        static let widthFraction: CGFloat = 0.8
        static let maxHeightFraction: CGFloat = 0.88
        static let minContentWidth: CGFloat = 720
        static let minContentHeight: CGFloat = 405
        static let defaultBrowsingContentSize = NSSize(width: 1440, height: 900)
        static let minBrowsingFrameHeight: CGFloat = 500
        static let minBrowsingFrameWidth: CGFloat = 800
        static let minVideoAspect: CGFloat = 0.55
        static let maxVideoAspect: CGFloat = 2.45
    }

    /// Snapshot the browsing window before any player autosize runs.
    func capturePrePlayerWindowFrame() {
        guard previousWindowFrame == nil,
              let window = Self.playbackHostWindow(),
              !window.styleMask.contains(.fullScreen)
        else { return }
        let frame = window.frame
        guard Self.isReasonableBrowsingFrame(frame) else { return }
        previousWindowFrame = frame
    }

    func restorePrePlayerWindowFrame(animated: Bool = true) {
        guard let window = Self.playbackHostWindow(),
              !window.styleMask.contains(.fullScreen)
        else { return }

        let target = Self.resolvedBrowsingWindowFrame(saved: previousWindowFrame, for: window)
        previousWindowFrame = nil
        applyWindowFrame(target, to: window, animated: animated)
    }

    func scheduleBrowsingWindowFrameCorrection() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(360))
            guard let self else { return }
            guard !self.isPresented, !self.isPlayerRevealed else { return }
            guard let window = Self.playbackHostWindow(),
                  !window.styleMask.contains(.fullScreen)
            else { return }
            guard !Self.isReasonableBrowsingFrame(window.frame) else { return }
            let target = Self.resolvedBrowsingWindowFrame(saved: nil, for: window)
            self.applyWindowFrame(target, to: window, animated: true)
        }
    }

    private func applyWindowFrame(_ frame: NSRect, to window: NSWindow, animated: Bool) {
        guard !NSEqualRects(window.frame, frame) else { return }
        window.setFrame(frame, display: true, animate: animated)
    }

    static func isReasonableBrowsingFrame(_ frame: NSRect) -> Bool {
        guard frame.width >= WindowAutosize.minBrowsingFrameWidth,
              frame.height >= WindowAutosize.minBrowsingFrameHeight
        else { return false }
        let aspect = frame.width / frame.height
        return aspect >= 1.1 && aspect <= 2.2
    }

    static func resolvedBrowsingWindowFrame(saved: NSRect?, for window: NSWindow) -> NSRect {
        if let saved, isReasonableBrowsingFrame(saved) {
            return saved
        }
        return defaultBrowsingWindowFrame(for: window)
    }

    static func defaultBrowsingWindowFrame(for window: NSWindow) -> NSRect {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var frame = NSWindow.frameRect(
            forContentRect: NSRect(origin: .zero, size: WindowAutosize.defaultBrowsingContentSize),
            styleMask: window.styleMask
        )
        frame.origin.x = visible.origin.x + floor((visible.width - frame.width) / 2)
        frame.origin.y = visible.origin.y + floor((visible.height - frame.height) / 2)
        return frame
    }

    private static func sanitizedVideoAspectRatio(for size: CGSize) -> CGFloat? {
        let width = abs(size.width)
        let height = abs(size.height)
        guard width > 1, height > 1 else { return nil }
        let ratio = width / height
        guard ratio.isFinite,
              ratio >= WindowAutosize.minVideoAspect,
              ratio <= WindowAutosize.maxVideoAspect
        else { return nil }
        return ratio
    }

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
        guard let window = Self.playbackHostWindow(), !window.styleMask.contains(.fullScreen) else { return }
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
        guard let videoRatio = Self.sanitizedVideoAspectRatio(for: aspectRatio) else { return }
        guard let window = Self.playbackHostWindow(), !window.styleMask.contains(.fullScreen) else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }

        capturePrePlayerWindowFrame()

        if hasResizedForCurrentVideo {
            guard let previous = lastAutosizedVideoSize,
                  let previousRatio = Self.sanitizedVideoAspectRatio(for: previous)
            else { return }
            guard abs(previousRatio - videoRatio) / max(previousRatio, 0.01) > 0.03 else { return }
        }

        let visible = screen.visibleFrame
        var contentWidth = floor(visible.width * WindowAutosize.widthFraction)
        var contentHeight = floor(contentWidth / videoRatio)

        let maxContentHeight = floor(visible.height * WindowAutosize.maxHeightFraction)
        if contentHeight > maxContentHeight {
            contentHeight = maxContentHeight
            contentWidth = floor(contentHeight * videoRatio)
        }

        contentWidth = max(contentWidth, WindowAutosize.minContentWidth)
        contentHeight = max(contentHeight, WindowAutosize.minContentHeight)

        let contentSize = NSSize(width: contentWidth, height: contentHeight)
        var frameRect = NSWindow.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: window.styleMask
        )

        frameRect.origin.x = visible.origin.x + floor((visible.width - frameRect.width) / 2)
        frameRect.origin.y = visible.origin.y + floor((visible.height - frameRect.height) / 2)

        if frameRect.origin.x < visible.minX {
            frameRect.origin.x = visible.minX
        }
        if frameRect.origin.y < visible.minY {
            frameRect.origin.y = visible.minY
        }
        if frameRect.maxX > visible.maxX {
            frameRect.origin.x = visible.maxX - frameRect.width
        }
        if frameRect.maxY > visible.maxY {
            frameRect.origin.y = visible.maxY - frameRect.height
        }

        let currentFrame = window.frame
        let changed =
            abs(currentFrame.width - frameRect.width) > 8
            || abs(currentFrame.height - frameRect.height) > 8
            || abs(currentFrame.midX - frameRect.midX) > 8
            || abs(currentFrame.midY - frameRect.midY) > 8

        guard changed else {
            hasResizedForCurrentVideo = true
            lastAutosizedVideoSize = aspectRatio
            return
        }

        hasResizedForCurrentVideo = true
        lastAutosizedVideoSize = aspectRatio
        window.setFrame(frameRect, display: true, animate: true)
        PlaybackLog.log(
            "autosized window content=\(Int(contentWidth))x\(Int(contentHeight)) "
                + "frame=\(Int(frameRect.width))x\(Int(frameRect.height)) "
                + "video=\(Int(aspectRatio.width))x\(Int(aspectRatio.height))"
        )
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
