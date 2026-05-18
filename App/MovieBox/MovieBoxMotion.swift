import SwiftUI

enum MovieBoxMotion {
    /// Page and detail navigation — simple cross-fade, no slide or scale.
    static let navigation = Animation.easeInOut(duration: 0.28)

    /// Pill tab bar width morph (search expand, menu collapse).
    static let chrome = Animation.spring(response: 0.42, dampingFraction: 0.72)

    /// Active tab highlight glide — liquid matched-geometry spring.
    static let tabHighlight = Animation.spring(response: 0.38, dampingFraction: 0.58)

    /// App chrome ↔ full-screen player cross-fade.
    static let player = Animation.easeInOut(duration: 0.38)

    static let playerStepDelay: Duration = .milliseconds(220)
}
