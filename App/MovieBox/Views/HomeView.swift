import CoreMLEngine
import CoreMetadata
import CoreStorage
import DesignSystem
import MovieBoxCore
import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Query private var settings: [AppSettings]
    @Query private var ratings: [RatingRecord]
    @Query private var storedMovies: [MovieRecord]
    @State private var rows: [MetadataCategory: [Movie]] = [:]
    @State private var recommended: [Movie] = []
    @State private var continueWatching: [MovieRecord] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        ZStack {
            // Ambient subtle background gradient for an elite glow
            RadialGradient(
                colors: [Color.red.opacity(0.12), Color.clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 480
            )
            .ignoresSafeArea()
            


            if metadataMode == nil {
                ContentUnavailableView(
                    "Metadata Not Configured",
                    systemImage: "key",
                    description: Text("Open Settings and add either a backend URL with app token or a TMDB bearer token.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    ZStack(alignment: .top) {
                        LazyVStack(alignment: .leading, spacing: 42) {
                                 if let trending = rows[.trending], !trending.isEmpty {
                                      HeroCarousel(movies: Array(trending.prefix(5)), kind: .movie) { movie in
                                          router.showDetail(id: movie.id, kind: .movie)
                                      }
                                      .frame(maxWidth: .infinity)
                                  }

                            if !continueWatching.isEmpty {
                                ContinueWatchingRow(records: continueWatching) { record in
                                    router.showDetail(id: record.tmdbId, kind: record.mediaKindEnum)
                                }
                            }

                            if !recommended.isEmpty {
                                HorizontalMovieRow(title: "Recommended For You", items: recommended) { movie in
                                    MoviePosterCard(
                                        title: movie.title,
                                        subtitle: movie.releaseDate,
                                        posterURL: MetadataClient().imageURL(path: movie.posterPath)
                                    ) {
                                        router.showDetail(id: movie.id, kind: .movie)
                                    }
                                }
                            }

                            if isLoading && rows.isEmpty {
                                ProgressView("Loading movies...")
                                    .controlSize(.large)
                                    .frame(maxWidth: .infinity, minHeight: 260)
                            }

                            ForEach(MetadataCategory.allCases) { category in
                                if let movies = rows[category], !movies.isEmpty {
                                    HorizontalMovieRow(title: category.rawValue, items: movies) { movie in
                                        MoviePosterCard(
                                            title: movie.title,
                                            subtitle: movie.releaseDate,
                                            posterURL: MetadataClient().imageURL(path: movie.posterPath)
                                        ) {
                                            router.showDetail(id: movie.id, kind: .movie)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 28)
                        
                        // Scroll offset tracker (invisible)
                        GeometryReader { geo in
                            Color.clear.preference(key: ScrollOffsetPreferenceKey.self, value: geo.frame(in: .named("scroll")).minY)
                        }
                        .frame(height: 0)
                    }
                }
                .coordinateSpace(name: "scroll")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                    scrollOffset = offset
                }
                .scrollIndicators(.hidden)
                .blur(radius: errorMessage != nil ? 18 : 0)
                .opacity(rows.isEmpty ? 0 : 1)
            }
            
            // Full screen loading (if rows is empty)
            if isLoading && rows.isEmpty && metadataMode != nil {
                ProgressView("Loading movies...")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Fixed centered Error card floating on a blurred panel
            if let errorMessage {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()
                    
                    if let mode = metadataMode {
                        RetryCard(message: errorMessage) {
                            Task { await load(mode: mode) }
                        }
                        .frame(maxWidth: 420)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else {
                        RetryCard(message: errorMessage) {
                            if let mode = metadataMode {
                                Task { await load(mode: mode) }
                            }
                        }
                        .frame(maxWidth: 420)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: settingsKey) {
            guard metadataMode != nil else { return }
            guard let mode = await MetadataSettings.resolveMode(from: settings) else { return }
            await load(mode: mode)
        }
    }

    private var metadataMode: MetadataEndpointMode? {
        MetadataSettings.mode(from: settings)
    }

    private var settingsKey: String {
        guard let setting = settings.first else { return "missing" }
        return "\(setting.proxyBaseURL)|\(setting.tmdbBearerToken)|\(setting.posterSize)|\(setting.backdropSize)|\(setting.requestTimeout)"
    }

    private func load(mode: MetadataEndpointMode) async {
        isLoading = true
        errorMessage = nil
        do {
            rows = try await CatalogLoader.loadHomeRows(mode: mode)
            let trending = rows[.trending] ?? []
            let popular = rows[.popular] ?? []
            let topRated = rows[.topRated] ?? []
            let allMovies = trending + popular + topRated
            let ratingSignals = ratings.map { RatingSignal(tmdbId: $0.tmdbId, rating: $0.rating, genreIds: $0.genres) }
            if !ratingSignals.isEmpty {
                let engine = GenreAffinityEngine()
                let candidates = allMovies.map { RecommendationCandidate(id: $0.id, genreIds: $0.genreIds, baseScore: Float($0.voteAverage / 10)) }
                let ranked = await engine.rank(candidates: candidates, ratings: ratingSignals)
                let rankedIds = Set(ranked.map(\.id))
                recommended = allMovies.filter { rankedIds.contains($0.id) }.prefix(12).map { $0 }
            }

            continueWatching = storedMovies
                .filter { $0.watchedFraction > 0.05 && $0.watchedFraction < 0.95 }
                .sorted { ($0.lastWatchedAt ?? .distantPast) > ($1.lastWatchedAt ?? .distantPast) }
                .prefix(8)
                .map { $0 }
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }
            MetadataErrorLogger.record(error, context: "Home catalog load")
            errorMessage = MetadataErrorLogger.userMessage(
                for: error,
                backendURL: settings.first?.proxyBaseURL
            )
        }
        isLoading = false
    }
}

private struct ContinueWatchingRow: View {
    @Environment(AppRouter.self) private var router
    let records: [MovieRecord]
    let action: (MovieRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue Watching")
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(records, id: \.tmdbId) { record in
                        Button {
                            action(record)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .frame(width: 180, height: 100)
                                    .overlay {
                                        CachedImageView(url: MetadataClient().imageURL(path: record.posterPath)) {
                                            Image(systemName: "film.stack")
                                                .font(.system(size: 28))
                                                .foregroundStyle(.secondary)
                                        } content: { image in
                                            image.resizable().scaledToFill()
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                    .overlay(alignment: .bottom) {
                                        ProgressView(value: record.watchedFraction)
                                            .progressViewStyle(.linear)
                                            .tint(.blue)
                                            .padding(.horizontal, 4)
                                            .padding(.bottom, 4)
                                    }

                                Text(record.title)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                    .frame(width: 180, alignment: .leading)

                                Text("\(Int(record.watchedFraction * 100))% watched")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 180, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
}
