import CoreMetadata
import DesignSystem
import SwiftUI

/// Tall featured cards with title, genres, and tagline — used only for dedicated spotlight shelves.
struct FeaturedSpotlightRow: View {
    let title: String
    let movies: [Movie]
    let kindForMovie: (Movie) -> MediaKind
    let onSelect: (Movie) -> Void

    private let cardWidth: CGFloat = 380
    private let cardHeight: CGFloat = 570

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)
                .padding(.horizontal, MovieBoxLayout.shelfHorizontalInset)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(movies) { movie in
                        FeaturedSpotlightCard(
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

private struct FeaturedSpotlightCard: View {
    let movie: Movie
    let kind: MediaKind
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                artwork

                LinearGradient(
                    colors: [.clear, .black.opacity(0.35), .black.opacity(0.88)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                if let badge = spotlightBadge {
                    VStack {
                        HStack {
                            Text(badge)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.45), in: Capsule())
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(14)
                }

                VStack(alignment: .leading, spacing: 8) {
                    AsyncLogoView(movieId: movie.id, title: movie.title, kind: kind)
                        .frame(maxWidth: width - 36, alignment: .leading)

                    Text(GenreLabelFormatter.metadataLine(kind: kind, genreIds: movie.genreIds))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)

                    if !movie.overview.isEmpty {
                        Text(movie.overview)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 22)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.32), radius: 20, x: 0, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(movie.title)
    }

    private var spotlightBadge: String? {
        if movie.voteAverage >= 8.0 { return "Top Rated" }
        if isRecentRelease { return "New Release" }
        return nil
    }

    private var isRecentRelease: Bool {
        let prefix = movie.releaseDate.prefix(10)
        guard prefix.count == 10 else { return false }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: String(prefix)) else { return false }
        return date > Calendar.current.date(byAdding: .day, value: -45, to: Date()) ?? .distantPast
    }

    @ViewBuilder
    private var artwork: some View {
        if let path = movie.backdropPath ?? movie.posterPath,
           let url = MetadataClient().imageURL(path: path, width: 780) {
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
                .font(.title2.bold())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(20)
        }
    }
}
