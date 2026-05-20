import SwiftUI
import CoreMetadata

struct GenreCard: Identifiable, Hashable {
    let id: Int
    let name: String
    let symbol: String
    let colors: [Color]
    let staticBackdropPath: String?

    static let movieGenres: [GenreCard] = [
        .init(id: 28, name: "Action", symbol: "burst.fill",
              colors: [Color(red: 0.90, green: 0.31, blue: 0.18), Color(red: 0.95, green: 0.62, blue: 0.16)],
              staticBackdropPath: "/cfT29Im5VDvjE0RpyKOSdCKZal7.jpg"), // The Dark Knight
        .init(id: 12, name: "Adventure", symbol: "map.fill",
              colors: [Color(red: 0.18, green: 0.55, blue: 0.32), Color(red: 0.82, green: 0.88, blue: 0.22)],
              staticBackdropPath: "/vL5LR6WdxWPjLPFRLe133jXWsh5.jpg"), // Avatar
        .init(id: 16, name: "Animation", symbol: "sparkles",
              colors: [Color(red: 0.40, green: 0.20, blue: 0.85), Color(red: 0.95, green: 0.36, blue: 0.74)],
              staticBackdropPath: "/dyJvKsNs2KP8qQnAXbRwDjblViy.jpg"), // Spirited Away
        .init(id: 35, name: "Comedy", symbol: "face.smiling.inverse",
              colors: [Color(red: 0.18, green: 0.78, blue: 0.84), Color(red: 0.62, green: 0.92, blue: 0.46)],
              staticBackdropPath: "/9udCLTxTFl28RxnK8Q05E154ZGa.jpg"), // The Grand Budapest Hotel
        .init(id: 80, name: "Crime", symbol: "shield.lefthalf.filled",
              colors: [Color(red: 0.42, green: 0.08, blue: 0.12), Color(red: 0.78, green: 0.15, blue: 0.16)],
              staticBackdropPath: "/tSPT36ZKlP2WVHJLM4cQPLSzv3b.jpg"), // The Godfather
        .init(id: 99, name: "Documentary", symbol: "doc.text.image",
              colors: [Color(red: 0.30, green: 0.30, blue: 0.35), Color(red: 0.55, green: 0.55, blue: 0.62)],
              staticBackdropPath: "/eSVvx8xys2NuFhl8fevXt41wX7v.jpg"), // Free Solo
        .init(id: 18, name: "Drama", symbol: "theatermasks.fill",
              colors: [Color(red: 0.14, green: 0.27, blue: 0.55), Color(red: 0.32, green: 0.66, blue: 0.86)],
              staticBackdropPath: "/zfbjgQE1uSd9wiPTX4VzsLi0rGG.jpg"), // The Shawshank Redemption
        .init(id: 10751, name: "Family", symbol: "person.3.fill",
              colors: [Color(red: 0.96, green: 0.55, blue: 0.32), Color(red: 0.99, green: 0.82, blue: 0.42)],
              staticBackdropPath: "/q00H8EqULYSK74lgevMkhmGGLHn.jpg"), // The Lion King
        .init(id: 14, name: "Fantasy", symbol: "wand.and.stars",
              colors: [Color(red: 0.32, green: 0.18, blue: 0.62), Color(red: 0.18, green: 0.72, blue: 0.74)],
              staticBackdropPath: "/a0lfia8tk8ifkrve0Tn8wkISUvs.jpg"), // The Lord of the Rings: Fellowship
        .init(id: 27, name: "Horror", symbol: "moon.stars.fill",
              colors: [Color(red: 0.18, green: 0.06, blue: 0.10), Color(red: 0.92, green: 0.38, blue: 0.12)],
              staticBackdropPath: "/mmd1HnuvAzFc4iuVJcnBrhDNEKr.jpg"), // The Shining
        .init(id: 10402, name: "Music", symbol: "music.note",
              colors: [Color(red: 0.86, green: 0.26, blue: 0.52), Color(red: 0.96, green: 0.70, blue: 0.28)],
              staticBackdropPath: "/nlPCdZlHtRNcF6C9hzUH4ebmV1w.jpg"), // La La Land
        .init(id: 9648, name: "Mystery", symbol: "magnifyingglass",
              colors: [Color(red: 0.13, green: 0.16, blue: 0.22), Color(red: 0.35, green: 0.40, blue: 0.52)],
              staticBackdropPath: "/rbZvGN1A1QyZuoKzhCw8QPmf2q0.jpg"), // Shutter Island
        .init(id: 10749, name: "Romance", symbol: "heart.fill",
              colors: [Color(red: 0.92, green: 0.38, blue: 0.62), Color(red: 0.96, green: 0.72, blue: 0.80)],
              staticBackdropPath: "/rzdPqYx7Um4FUZeD8wpXqjAUcEm.jpg"), // Titanic
        .init(id: 878, name: "Sci-Fi", symbol: "globe.americas.fill",
              colors: [Color(red: 0.10, green: 0.20, blue: 0.45), Color(red: 0.40, green: 0.86, blue: 0.95)],
              staticBackdropPath: "/mVr0UiqyltcfqxbAUcLl9zWL8ah.jpg"), // Blade Runner 2049
        .init(id: 53, name: "Thriller", symbol: "bolt.fill",
              colors: [Color(red: 0.20, green: 0.08, blue: 0.32), Color(red: 0.78, green: 0.16, blue: 0.55)],
              staticBackdropPath: "/8ZTVqvKDQ8emSGUEMjsS4yHAwrp.jpg"), // Inception
        .init(id: 10752, name: "War", symbol: "shield.fill",
              colors: [Color(red: 0.38, green: 0.38, blue: 0.38), Color(red: 0.18, green: 0.18, blue: 0.18)],
              staticBackdropPath: "/bdD39MpSVhKjxarTxLSfX6baoMP.jpg"), // Saving Private Ryan
        .init(id: 37, name: "Western", symbol: "binoculars.fill",
              colors: [Color(red: 0.84, green: 0.52, blue: 0.18), Color(red: 0.95, green: 0.74, blue: 0.36)],
              staticBackdropPath: "/Adrip2Jqzw56KeuV2nAxucKMNXA.jpg")  // The Good, the Bad and the Ugly
    ]
}

struct GenreCardView: View {
    let genre: GenreCard
    let imageURL: URL?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                // Background Gradient Base
                LinearGradient(colors: genre.colors, startPoint: .topLeading, endPoint: .bottomTrailing)

                // High-Quality Backdrop overlay (centered with progressive bottom blur)
                if let imageURL {
                    CachedImageView(url: imageURL) {
                        Color.clear
                    } content: { image in
                        Color.clear
                            .overlay(
                                ZStack {
                                    // Sharp backdrop image (fades out at bottom)
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .mask(
                                            LinearGradient(
                                                colors: [.black, .clear],
                                                startPoint: .center,
                                                endPoint: .bottom
                                            )
                                        )
                                    
                                    // Blurred backdrop image (fades in at bottom)
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .blur(radius: 12)
                                        .mask(
                                            LinearGradient(
                                                colors: [.clear, .black],
                                                startPoint: .center,
                                                endPoint: .bottom
                                            )
                                        )
                                },
                                alignment: .center
                            )
                            .opacity(0.5)                    // Lower image opacity to let rich colors shine through
                            .allowsHitTesting(false)
                    }
                    .layoutPriority(-1)
                }

                // Subtler dark vignette overlay at the bottom for readability of category titles
                LinearGradient(
                    colors: [.clear, .black.opacity(0.3)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                // Translucent Material Badge in top right
                Image(systemName: genre.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.2), in: Circle())
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                // Title
                Text(genre.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(12)
            }
            .aspectRatio(3/4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
            .overlay {
                if isHovered {
                    Color.white.opacity(0.06)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(genre.name) category")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
