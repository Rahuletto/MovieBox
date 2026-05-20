import SwiftUI
import CoreMetadata
import DesignSystem
import CoreStorage
import MovieBoxCore
import SwiftData
import Combine

struct HeroCarousel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Query private var settings: [AppSettings]

    let movies: [Movie]
    let kind: MediaKind
    let kindForMovie: ((Movie) -> MediaKind)?
    let action: (Movie) -> Void

    init(
        movies: [Movie],
        kind: MediaKind = .movie,
        kindForMovie: ((Movie) -> MediaKind)? = nil,
        action: @escaping (Movie) -> Void
    ) {
        self.movies = movies
        self.kind = kind
        self.kindForMovie = kindForMovie
        self.action = action
    }

    @State private var currentIndex: Int = 0
    @State private var progress: CGFloat = 0
    @State private var enrichmentByMovieID: [Int: MovieEnrichment] = [:]

    let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var fadeColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var contentColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var metadataMode: MetadataEndpointMode? {
        settings.first?.metadataMode
    }

    var body: some View {
        guard !movies.isEmpty else { return AnyView(EmptyView()) }
        let currentMovie = movies[currentIndex]
        let currentKind = kindForMovie?(currentMovie) ?? kind
        let enrichment = enrichmentByMovieID[currentMovie.id]
        let releaseYear: String? = {
            let year = currentMovie.releaseDate.prefix(4)
            return year.count == 4 ? String(year) : nil
        }()

        return AnyView(
            ZStack(alignment: .bottom) {
                ZStack {
                    if let backdropPath = currentMovie.backdropPath ?? currentMovie.posterPath,
                       let url = MetadataClient().imageURL(path: backdropPath, width: 1920) {
                        CachedImageView(url: url) {
                            fadeColor
                        } content: { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .transition(.opacity.animation(.easeInOut(duration: 0.5)))
                        }
                    } else {
                        fadeColor
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 620)
                .clipped()
                .id("hero-bg-\(currentIndex)")

                LinearGradient(colors: [.clear, fadeColor.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 620)

                HStack {
                    VStack(alignment: .leading, spacing: 20) {
                        Spacer()

                        AsyncLogoView(movieId: currentMovie.id, title: currentMovie.title, kind: currentKind)

                        HStack(spacing: 12) {
                            MediaMetadataRibbon(
                                year: releaseYear,
                                runtimeMinutes: currentMovie.runtime,
                                contentRating: enrichment?.rated,
                                labelColor: contentColor.opacity(0.85)
                            ) {
                                if let imdbRating = enrichment?.imdbRating {
                                    IMDBBadge(
                                        rating: imdbRating,
                                        enrichment: enrichment,
                                        onTap: nil
                                    )
                                }
                            }

                            if let rt = enrichment?.rottenTomatoes {
                                RottenTomatoesBadge(score: rt)
                            }
                        }

                        Text(currentMovie.overview)
                            .font(MovieBoxTypography.body)
                            .foregroundStyle(contentColor.opacity(0.9))
                            .lineLimit(3)
                            .frame(maxWidth: 600, alignment: .leading)

                        Button {
                            action(currentMovie)
                        } label: {
                            Label("Play Now", systemImage: "play.fill")
                                .font(.headline)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(.white, in: Capsule())
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 12)
                        .padding(.bottom, 60)
                    }
                    Spacer()
                }
                .padding(40)

                VStack(spacing: 12) {
                    Spacer()

                    HStack(spacing: 0) {
                        Button {
                            withAnimation(.easeInOut) {
                                currentIndex = (currentIndex - 1 + movies.count) % movies.count
                                progress = 0
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(contentColor)
                                .padding(12)
                        }
                        .buttonStyle(.plain)
                        .help("Previous movie")

                        Spacer()

                        HStack(spacing: 8) {
                            ForEach(0..<movies.count, id: \.self) { index in
                                if index == currentIndex {
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(contentColor.opacity(0.3))
                                            .frame(width: 40, height: 4)

                                        Capsule()
                                            .fill(contentColor)
                                            .frame(width: max(0, 40 * progress), height: 4)
                                    }
                                } else {
                                    Circle()
                                        .fill(contentColor.opacity(0.3))
                                        .frame(width: 6, height: 6)
                                }
                            }
                        }

                        Spacer()

                        Button {
                            withAnimation(.easeInOut) {
                                currentIndex = (currentIndex + 1) % movies.count
                                progress = 0
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(contentColor)
                                .padding(12)
                        }
                        .buttonStyle(.plain)
                        .help("Next movie")
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
            }
            .frame(height: 620)
            .ignoresSafeArea(edges: .horizontal)
            .contentShape(Rectangle())
            .onTapGesture {
                action(currentMovie)
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let translation = value.translation.width

                        if translation < -50 {
                            withAnimation(.easeInOut) {
                                currentIndex = (currentIndex + 1) % movies.count
                                progress = 0
                            }
                        } else if translation > 50 {
                            withAnimation(.easeInOut) {
                                currentIndex = (currentIndex - 1 + movies.count) % movies.count
                                progress = 0
                            }
                        }
                    }
            )
            .onReceive(timer) { _ in
                if progress < 1.0 {
                    progress += 0.05 / 5.0
                } else {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        currentIndex = (currentIndex + 1) % movies.count
                        progress = 0
                    }
                }
            }
            .task(id: currentMovie.id) {
                await loadEnrichment(for: currentMovie, kind: currentKind)
            }
        )
    }

    private func loadEnrichment(for movie: Movie, kind: MediaKind) async {
        guard enrichmentByMovieID[movie.id] == nil,
              let mode = metadataMode else { return }
        let client = MetadataClient(mode: mode)
        guard let detail = try? await client.movieDetail(id: movie.id, kind: kind) else { return }
        enrichmentByMovieID[movie.id] = detail.enrichment
    }
}
