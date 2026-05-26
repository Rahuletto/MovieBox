@preconcurrency import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


// Picture in Picture Delegate
public final class PlayerPiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
    private let state: PlayerState

    public init(state: PlayerState) {
        self.state = state
    }

    public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let activeState = self.state
        Task { @MainActor in
            activeState.pipHostView?.prepareForPictureInPicture()
            activeState.isPictureInPictureActive = true
            activeState.keepPlaybackAliveForPiP()
        }
    }

    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let activeState = self.state
        Task { @MainActor in
            activeState.keepPlaybackAliveForPiP()
        }
    }

    public func pictureInPictureControllerFailedToStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController, error: Error) {
        PlaybackLog.log("PiP failed to start: \(error.localizedDescription)")
        let activeState = self.state
        Task { @MainActor in
            activeState.pipHostView?.restoreAfterPictureInPicture()
            activeState.isPictureInPictureActive = false
        }
    }

    public func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    }

    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let activeState = self.state
        Task { @MainActor in
            activeState.pipHostView?.restoreAfterPictureInPicture()
            activeState.isPictureInPictureActive = false
            guard activeState.isPlaybackChromeHidden, activeState.isPresented else { return }
            if activeState.dismissPlaybackWhenPiPCloses {
                activeState.dismissFromDetachedPiPClose()
            }
        }
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        let completion = PiPRestoreCompletion(completionHandler)
        let activeState = self.state
        Task { @MainActor in
            activeState.pipHostView?.restoreAfterPictureInPicture()
            activeState.dismissPlaybackWhenPiPCloses = false
            if activeState.isPresented {
                activeState.restorePlaybackChrome()
            }
            completion.finish(true)
        }
    }
}

private final class PiPRestoreCompletion: @unchecked Sendable {
    private let handler: (Bool) -> Void

    init(_ handler: @escaping (Bool) -> Void) {
        self.handler = handler
    }

    func finish(_ success: Bool) {
        handler(success)
    }
}
