import AppKit

enum PlaybackHaptics {
    enum Kind {
        case selection
        case activate
    }

    static func play(_ kind: Kind) {
        guard NSApp?.isActive != false else { return }
        let pattern: NSHapticFeedbackManager.FeedbackPattern = switch kind {
        case .selection: .alignment
        case .activate: .generic
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }
}
