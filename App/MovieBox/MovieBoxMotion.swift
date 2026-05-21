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

    /// Stream pill placement morph (bottom ↔ top).
    static let streamPill = Animation.easeInOut(duration: 0.34)

    /// Stream pill hover expand (separate from placement morph).
    static let streamPillHover = Animation.easeInOut(duration: 0.22)

    /// Stream pill first appear / dismiss (fade only).
    static let streamPillAppear = Animation.easeInOut(duration: 0.28)

    /// Pill progress width — gentle, no text/layout coupling.
    static let streamPillProgress = Animation.easeOut(duration: 0.45)

    static let playerStepDelay: Duration = .milliseconds(220)
}
