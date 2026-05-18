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
                                .init(color: .clear, location: 0.55),
                                .init(color: .black.opacity(0.35), location: 0.85),
                                .init(color: .black.opacity(0.75), location: 1),
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
