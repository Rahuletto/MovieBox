import SwiftUI

/// Native backdrop blur behind scrolling detail sections; grows with scroll position.
struct ScrollFillingBlurBackground: View {
    var topExtension: CGFloat = 360

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    LinearGradient(
                        colors: [Color.black.opacity(0.20), Color.black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.00),
                                .init(color: .white.opacity(0.12), location: 0.15),
                                .init(color: .white.opacity(0.30), location: 0.30),
                                .init(color: .white.opacity(0.50), location: 0.45),
                                .init(color: .white.opacity(0.70), location: 0.60),
                                .init(color: .white.opacity(0.85), location: 0.75),
                                .init(color: .white.opacity(0.95), location: 0.90),
                                .init(color: .white, location: 1.00),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 340)

                        Rectangle().fill(.white)
                    }
                }
                .frame(
                    width: geo.size.width,
                    height: geo.size.height + topExtension
                )
                .offset(y: -topExtension)
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }
}
