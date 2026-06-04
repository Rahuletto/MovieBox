import CoreMetadata
import CoreStorage
import DesignSystem
import MovieBoxCore
import SwiftUI

struct ContinueWatchingCard: View {
    let record: MovieRecord
    let backdropURL: URL?
    let action: () -> Void

    private let cardWidth: CGFloat = 360
    private let cardHeight: CGFloat = 200
    private let logoMaxHeight: CGFloat = 64
    private let progressRowHeight: CGFloat = 20
    private let bottomHorizontalPadding: CGFloat = 10
    private let bottomCornerInset: CGFloat = 16

    private var bottomContentWidth: CGFloat {
        cardWidth - bottomHorizontalPadding - bottomCornerInset
    }

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: cardWidth, height: cardHeight)
                .overlay {
                    backdrop
                }
                .overlay(alignment: .bottomLeading) {
                    bottomChrome
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
    }

    private var bottomChrome: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [.clear, .black.opacity(0.4), .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: bottomChromeHeight)

            VStack(alignment: .leading, spacing: 4) {
                AsyncLogoView(
                    movieId: record.tmdbId,
                    title: record.title,
                    kind: record.mediaKindEnum,
                    maxLogoHeight: logoMaxHeight,
                    fallbackTitleSize: 24
                )
                .frame(width: bottomContentWidth, height: logoMaxHeight, alignment: .bottomLeading)

                ContinueWatchingPlaybackOverlay(
                    progress: WatchProgressStore.progressFraction(for: record),
                    label: WatchProgressStore.continueWatchingOverlayLabel(for: record),
                    includesBackdropGradient: false
                )
                .frame(width: bottomContentWidth, height: progressRowHeight)
            }
            .padding(.leading, bottomHorizontalPadding)
            .padding(.trailing, bottomCornerInset)
            .padding(.bottom, bottomCornerInset)
            .frame(width: cardWidth, alignment: .leading)
        }
        .frame(width: cardWidth, height: bottomChromeHeight, alignment: .bottomLeading)
    }

    private var bottomChromeHeight: CGFloat {
        logoMaxHeight + 4 + progressRowHeight + 12
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
