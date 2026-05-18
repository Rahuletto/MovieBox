import SwiftUI

extension View {
    /// Keeps every tab mounted while hiding inactive tabs (preserves scroll state).
    func rootTabVisible(_ isVisible: Bool) -> some View {
        opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
    }
}
