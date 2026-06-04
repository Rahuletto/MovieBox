import CoreMetadata
import DesignSystem
import SwiftUI

/// Wide cinematic cards (16:9) with logo, metadata, and tagline overlay.
struct FeaturedLandscapeRow: View {
    let title: String
    let movies: [Movie]
    let kindForMovie: (Movie) -> MediaKind
    let onSelect: (Movie) -> Void

    private let cardWidth: CGFloat = MovieBoxLayout.landscapeCardWidth
    private let cardHeight: CGFloat = MovieBoxLayout.landscapeCardHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)
                .padding(.horizontal, MovieBoxLayout.shelfHorizontalInset)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(movies) { movie in
                        FeaturedLandscapeCard(
                            movie: movie,
                            kind: kindForMovie(movie),
                            width: cardWidth,
                            height: cardHeight,
                            action: { onSelect(movie) }
                        )
                    }
                }
                .padding(.horizontal, MovieBoxLayout.shelfHorizontalInset)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

private struct FeaturedLandscapeCard: View {
    let movie: Movie
    let kind: MediaKind
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    private let contentHorizontalPadding: CGFloat = 28
    private let contentBottomPadding: CGFloat = 22

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                artwork

                LinearGradient(
                    colors: [.clear, .black.opacity(0.25), .black.opacity(0.82)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 6) {
                    AsyncLogoView(
                        movieId: movie.id,
                        title: movie.title,
                        kind: kind,
                        maxLogoHeight: 82,
                        fallbackTitleSize: 32
                    )
                    .frame(maxWidth: min(width - contentHorizontalPadding * 2, 300), alignment: .leading)
                    .scaleEffect(0.92, anchor: .bottomLeading)

                    Text(GenreLabelFormatter.metadataLine(kind: kind, genreIds: movie.genreIds))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)

                    if !movie.overview.isEmpty {
                        Text(movie.overview)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: width - contentHorizontalPadding * 2, alignment: .leading)
                    }
                }
                .padding(.horizontal, contentHorizontalPadding)
                .padding(.bottom, contentBottomPadding)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(movie.title)
    }

    @ViewBuilder
    private var artwork: some View {
        if let path = movie.backdropPath ?? movie.posterPath,
           let url = MetadataClient().imageURL(path: path, width: 1280) {
            CachedImageView(url: url) {
                placeholder
            } content: { image in
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.primary.opacity(0.08)
            Text(movie.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
        }
    }
}
