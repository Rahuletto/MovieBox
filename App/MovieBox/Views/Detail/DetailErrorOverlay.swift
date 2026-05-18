import SwiftUI

struct DetailErrorOverlay: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            RetryCard(message: message, retry: onRetry)
                .frame(maxWidth: 420)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
