@preconcurrency import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


@MainActor
extension PlayerState {
    func cancelHUDPillDismissTask() {
        hudPillDismissTask?.cancel()
        hudPillDismissTask = nil
    }

    func setHUDStatusPill(_ pill: PlayerHUDStatusPillModel?) {
        hudStatusPill = pill
    }

    func presentVideoGravityHUDPill() {
        presentTransientHUDPill(.videoGravity(title: videoGravityHUDTitle, icon: "aspectratio")) { pill in
            if case .videoGravity = pill { return true }
            return false
        }
    }

    func presentPlaybackRateHUDPill() {
        presentTransientHUDPill(.playbackRate(rate: playbackRate)) { pill in
            if case .playbackRate = pill { return true }
            return false
        }
    }

    func presentQualityBadgesHUDPillIfNeeded() {
        guard !qualityBadgePillShownForCurrentItem, !isFastScanning else { return }
        let kinds = qualityBadgeKinds
        guard !kinds.isEmpty else { return }
        // Already visible (e.g. repeated readyToPlay while probing) — don't extend or re-animate.
        if case .qualityBadges(let showing) = hudStatusPill, showing == kinds {
            qualityBadgePillShownForCurrentItem = true
            return
        }
        qualityBadgePillShownForCurrentItem = true
        presentTransientHUDPill(
            .qualityBadges(kinds: kinds),
            dismissAfter: 5
        ) { pill in
            if case .qualityBadges = pill { return true }
            return false
        }
    }

    func presentTransientHUDPill(
        _ pill: PlayerHUDStatusPillModel,
        dismissAfter seconds: TimeInterval = 2,
        shouldDismiss: @escaping (PlayerHUDStatusPillModel) -> Bool
    ) {
        cancelHUDPillDismissTask()
        hudPillDismissGeneration += 1
        let generation = hudPillDismissGeneration
        setHUDStatusPill(pill)
        hudPillDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            guard self.hudPillDismissGeneration == generation else { return }
            if let current = self.hudStatusPill, shouldDismiss(current) {
                self.setHUDStatusPill(nil)
            }
        }
    }

    public var videoGravityHUDTitle: String {
        switch videoGravity {
        case .resizeAspect: return "Fit Screen"
        case .resizeAspectFill: return "Fill"
        case .resize: return "100%"
        default: return "Fit Screen"
        }
    }

    public var videoGravityLabel: String {
        switch videoGravity {
        case .resizeAspect: return "Fit"
        case .resizeAspectFill: return "Fill"
        case .resize: return "100%"
        default: return "Fit"
        }
    }


}
