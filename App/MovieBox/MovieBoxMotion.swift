import SwiftUI

enum MovieBoxMotion {
    /// Page and detail navigation — simple cross-fade, no slide or scale.
    static let navigation = Animation.easeInOut(duration: 0.28)

    /// Pill tab bar, search expand, and other chrome.
    static let chrome = Animation.easeInOut(duration: 0.34)

    /// Active tab highlight glide inside the pill.
    static let tabHighlight = Animation.easeInOut(duration: 0.32)
}
