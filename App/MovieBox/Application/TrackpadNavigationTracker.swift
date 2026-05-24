import AppKit
import SwiftUI

/// Monitors local trackpad scroll/swipe events on macOS to trigger back navigation
/// when a user swipes from left to right (going back).
@MainActor
final class TrackpadNavigationTracker {
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var hasTriggered = false
    private var isSwipeAllowed = false
    private var lastEventTime: TimeInterval = 0
    private var monitor: Any?

    init(router: AppRouter) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self else { return event }
            self.handleScrollWheel(event, router: router)
            return event
        }
    }

    deinit {
        if let monitor = monitor {
            // Need to remove monitor on main thread since it was created there
            let m = monitor
            DispatchQueue.main.async {
                NSEvent.removeMonitor(m)
            }
        }
    }

    private func handleScrollWheel(_ event: NSEvent, router: AppRouter) {
        // Only run if we are showing a detail page (so we can navigate back)
        guard router.isShowingDetail else { return }

        let now = NSDate.timeIntervalSinceReferenceDate
        let isBegan = event.phase == .began || now - lastEventTime > 0.3

        if isBegan {
            accumulatedX = 0
            accumulatedY = 0
            hasTriggered = false

            // To avoid conflicts with horizontal scrolling carousels in the main page view,
            // we only allow swipe-to-back if the cursor starts on the left 35% of the window.
            if let window = event.window {
                let windowWidth = window.frame.width
                let limit = min(350, windowWidth * 0.35)
                isSwipeAllowed = event.locationInWindow.x < limit
            } else {
                isSwipeAllowed = true // Fallback
            }
        }

        lastEventTime = now

        guard isSwipeAllowed else { return }

        accumulatedX += event.scrollingDeltaX
        accumulatedY += event.scrollingDeltaY

        if !hasTriggered {
            let absX = abs(accumulatedX)
            let absY = abs(accumulatedY)

            // Require horizontal swipe to be dominant and exceed threshold
            if absX > 15 && absX > absY * 2.0 {
                if accumulatedX > 80 { // Swiped right (left-to-right gesture) -> go back
                    hasTriggered = true
                    triggerBack(router: router)
                }
            }
        }
    }

    private func triggerBack(router: AppRouter) {
        if case .personDetail = router.selectedRoute {
            router.backFromPerson()
        } else if case .movieDetail = router.selectedRoute {
            router.backFromDetail()
        }
    }
}
