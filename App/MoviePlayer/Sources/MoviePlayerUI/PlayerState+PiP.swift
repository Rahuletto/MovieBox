@preconcurrency import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


@MainActor
extension PlayerState {
    func teardownPiP() {
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        pipHostView?.restoreAfterPictureInPicture()
        pipPossibleObservation?.invalidate()
        pipPossibleObservation = nil
        pipController = nil
        pipDelegate = nil
        pipPlayerLayer = nil
        isPictureInPictureActive = false
        isPictureInPicturePossible = false
    }

    public func setupPiP(with playerLayer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        if pipPlayerLayer === playerLayer, pipController != nil { return }
        if pipController?.isPictureInPictureActive == true { return }

        teardownPiP()

        pipPlayerLayer = playerLayer
        let delegate = PlayerPiPDelegate(state: self)
        pipDelegate = delegate

        let contentSource = AVPictureInPictureController.ContentSource(playerLayer: playerLayer)
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = delegate
        pipController = controller

        pipPossibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            DispatchQueue.main.async { [weak self] in
                self?.isPictureInPicturePossible = possible
            }
        }
        isPictureInPicturePossible = controller.isPictureInPicturePossible
    }

    public func togglePictureInPicture() {
        guard let controller = pipController else {
            PlaybackLog.log("PiP unavailable — controller not ready")
            return
        }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            dismissPlaybackWhenPiPCloses = false
            guard controller.isPictureInPicturePossible else {
                PlaybackLog.log("PiP unavailable — not possible yet")
                return
            }
            pipHostView?.prepareForPictureInPicture()
            pipHostView?.window?.layoutIfNeeded()
            controller.startPictureInPicture()
        }
    }

    @discardableResult
    public func startPictureInPictureIfPossible() -> Bool {
        guard let controller = pipController else { return false }
        if controller.isPictureInPictureActive { return true }
        guard controller.isPictureInPicturePossible else { return false }
        pipHostView?.prepareForPictureInPicture()
        pipHostView?.window?.layoutIfNeeded()
        controller.startPictureInPicture()
        return true
    }

    /// Keeps torrent/custom streams playing when entering PiP or browsing behind the player.
    func keepPlaybackAliveForPiP() {
        guard userWantsPlayback else { return }
        if playbackRate <= 0 { playbackRate = 1.0 }
        if player.timeControlStatus != .playing {
            player.playImmediately(atRate: Float(playbackRate))
        }
        nudgePlaybackIfStalled()
    }

    /// Hides full-screen player chrome, keeps AVPlayer running, and enters PiP when supported.
    public func minimizeToPictureInPicture() {
        guard isPresented else { return }
        dismissPlaybackWhenPiPCloses = true
        presentationTransitionTask?.cancel()
        withAnimation(.easeInOut(duration: 0.38)) {
            isPlaybackChromeHidden = true
            isPlayerRevealed = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            for attempt in 0..<6 {
                if startPictureInPictureIfPossible() { return }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    public func restorePlaybackChrome() {
        guard isPresented else { return }
        dismissPlaybackWhenPiPCloses = false
        presentationTransitionTask?.cancel()
        withAnimation(.easeInOut(duration: 0.38)) {
            isPlaybackChromeHidden = false
            isPlayerRevealed = true
        }
    }

    /// PiP closed via X while browsing — stop video, do not reopen the in-app player.
    func dismissFromDetachedPiPClose() {
        dismissPlaybackWhenPiPCloses = false
        dismiss()
    }

}
