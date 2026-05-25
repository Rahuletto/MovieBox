import CoreMetadata
import CoreStorage
import DesignSystem
import SwiftUI

struct ContinueWatchingCard: View {
    let record: MovieRecord
    let backdropURL: URL?
    let action: () -> Void

    private let cardWidth: CGFloat = 360
    private let cardHeight: CGFloat = 200

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: cardWidth, height: cardHeight)
                .overlay {
                    backdrop
                }
                .overlay {
                    ContinueWatchingPlaybackOverlay(
                        progress: WatchProgressStore.progressFraction(for: record),
                        label: WatchProgressStore.continueWatchingOverlayLabel(for: record)
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
    }

    @ViewBuilder
    private var backdrop: some View {
        if let backdropURL {
            CachedImageView(url: backdropURL) {
                ProgressView()
            } content: { image in
                image.resizable().scaledToFill()
            }
            .id(backdropURL)
        } else {
            ZStack {
                Color.primary.opacity(0.06)
                Image(systemName: "film.stack")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var accessibilityTitle: String {
        var parts = [record.title]
        if let label = WatchProgressStore.continueWatchingOverlayLabel(for: record) {
            parts.append(label)
        }
        return parts.joined(separator: ", ")
    }
}
