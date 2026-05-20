import CoreMetadata
import DesignSystem
import SwiftUI

struct PersonProfileBackdrop: View {
    let profilePath: String?

    private var imageURL: URL? {
        guard let profilePath else { return nil }
        return MetadataClient().imageURL(path: profilePath, width: 780)
    }

    var body: some View {
        GeometryReader { geo in
            if let imageURL {
                CachedImageView(url: imageURL) {
                    fallback(size: geo.size)
                } content: { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 28)
                        .overlay(
                            LinearGradient(
                                stops: [
                                    .init(color: .black.opacity(0.35), location: 0),
                                    .init(color: .black.opacity(0.5), location: 0.5),
                                    .init(color: .black.opacity(0.75), location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            } else {
                fallback(size: geo.size)
            }
        }
    }

    private func fallback(size: CGSize) -> some View {
        ZStack {
            Color(white: 0.08)
            Image(systemName: "person.fill")
                .font(.system(size: 120))
                .foregroundStyle(.white.opacity(0.12))
        }
        .frame(width: size.width, height: size.height)
    }
}
