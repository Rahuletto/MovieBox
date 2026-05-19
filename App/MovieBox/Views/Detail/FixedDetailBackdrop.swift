import CoreMetadata
import DesignSystem
import SwiftUI

/// Fixed, sharp full-window backdrop. Blur is provided by the scrolling content's
/// material background (`ScrollFillingBlurBackground`).
struct FixedDetailBackdrop: View {
    let backdropPath: String?

    private var backdropURL: URL? {
        guard let path = backdropPath else { return nil }
        return MetadataClient().imageURL(path: path, width: 1920)
    }

    var body: some View {
        GeometryReader { geo in
            backdropImage(size: geo.size)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
    }

    @ViewBuilder
    private func backdropImage(size: CGSize) -> some View {
        if let backdropURL {
            CachedImageView(url: backdropURL) {
                Color.clear
            } content: { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .overlay(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 0.42),
                                .init(color: .black.opacity(0.10), location: 0.58),
                                .init(color: .black.opacity(0.28), location: 0.74),
                                .init(color: .black.opacity(0.48), location: 0.88),
                                .init(color: .black.opacity(0.68), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        } else {
            Color.clear
        }
    }
}
