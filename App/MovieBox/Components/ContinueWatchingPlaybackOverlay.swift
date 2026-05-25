import SwiftUI

/// Bottom overlay on continue-watching banners — play icon, progress, and `S1, E1 • 47m` label.
struct ContinueWatchingPlaybackOverlay: View {
    let progress: Double
    let label: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, .black.opacity(0.35), .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)

                progressBar

                if let label {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .padding(.top, 28)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.35))
                Capsule()
                    .fill(.white)
                    .frame(width: max(3, geo.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: 3)
        .frame(maxWidth: .infinity)
    }
}
