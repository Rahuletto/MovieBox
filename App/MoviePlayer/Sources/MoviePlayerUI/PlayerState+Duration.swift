import AVFoundation
import Foundation

@MainActor
extension PlayerState {
    /// Applies AVPlayer-reported duration without shrinking below a known full runtime.
    func adoptDurationFromPlayer(_ seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        if let trusted = trustedDurationSeconds, seconds < trusted * 0.85 {
            return
        }
        if let trusted = trustedDurationSeconds {
            duration = max(trusted, seconds)
            if seconds >= trusted * 0.95 {
                trustedDurationSeconds = nil
            }
        } else {
            duration = seconds
        }
    }
}
