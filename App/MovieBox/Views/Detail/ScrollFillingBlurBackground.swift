import SwiftUI

/// Native backdrop blur behind scrolling detail sections; grows with scroll position.
struct ScrollFillingBlurBackground: View {
    var topExtension: CGFloat = 400
    private let fadeHeight: CGFloat = 420

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.06), location: 0),
                            .init(color: .black.opacity(0.22), location: 0.45),
                            .init(color: .black.opacity(0.48), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(
                            stops: Self.smoothRevealStops(steps: 16),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: fadeHeight)

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

    /// Smoothstep mask — avoids visible bands in the progressive blur.
    private static func smoothRevealStops(steps: Int) -> [Gradient.Stop] {
        guard steps >= 2 else {
            return [.init(color: .white, location: 1)]
        }
        return (0..<steps).map { index in
            let t = Double(index) / Double(steps - 1)
            let opacity = t * t * (3 - 2 * t)
            return .init(color: .white.opacity(opacity), location: t)
        }
    }
}
