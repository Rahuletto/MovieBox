import SwiftUI

/// Bottom overlay on continue-watching banners — play icon, progress, and `S1, E1 • 47m` label.
struct ContinueWatchingPlaybackOverlay: View {
    let progress: Double
    let label: String?
    /// When false, only the progress row (for stacking under a title logo in the same bottom chrome).
    var includesBackdropGradient: Bool = true
    var showsPlayIcon: Bool = true
    /// Extra inset for the time label from the trailing/bottom edges of its container.
    var labelEdgeInset: CGFloat = 0
    var body: some View {
        if includesBackdropGradient {
            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.35), .black.opacity(0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(maxHeight: .infinity)

                progressRow
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        } else {
            progressRow
                .padding(.trailing, labelEdgeInset)
                .padding(.bottom, labelEdgeInset)
        }
    }

    var progressRow: some View {
        HStack(spacing: 8) {
            if showsPlayIcon {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }

            progressBar

            if let label {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
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
