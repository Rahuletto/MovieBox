import CoreMetadata
import CoreStorage
import DesignSystem
import MovieBoxCore
import SwiftData
import SwiftUI

struct GenreResultsView: View {
    @Environment(AppRouter.self) private var router
    @Query private var settings: [AppSettings]
    let genre: GenreCard
    let onBack: () -> Void

    @State private var movies: [Movie] = []
    @State private var shows: [Movie] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            // Main grid content
            VStack(alignment: .leading, spacing: 18) {
                if !movies.isEmpty {
                    sectionGrid(title: "Movies", items: movies, kind: .movie)
                }
                if !shows.isEmpty {
                    sectionGrid(title: "TV Shows", items: shows, kind: .tv)
                }
                if movies.isEmpty && shows.isEmpty && !isLoading && errorMessage == nil {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "film.stack",
                        description: Text("Nothing found for \(genre.name).")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .blur(radius: errorMessage != nil ? 18 : 0)
            .opacity(movies.isEmpty && shows.isEmpty ? 0 : 1)

            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 220)
            }

            // Fixed centered error card inside the genre panel
            if let errorMessage {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()
                    
                    RetryCard(message: errorMessage) {
                        Task { await load() }
                    }
                    .frame(maxWidth: 420)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: genre.id) { await load() }
    }

    @ViewBuilder
    private func sectionGrid(title: String, items: [Movie], kind: MediaKind) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(MovieBoxTypography.title)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 170), spacing: 16)], spacing: 22) {
                ForEach(items) { movie in
                    MoviePosterCard(
                        title: movie.title,
                        subtitle: movie.releaseDate,
                        posterURL: MetadataClient().posterDisplayURL(
                            posterPath: movie.posterPath,
                            backdropPath: movie.backdropPath
                        )
                    ) {
                        router.showDetail(id: movie.id, kind: kind)
                    }
                }
            }
        }
    }

    private func load() async {
        guard let mode = MetadataSettings.mode(from: settings) else {
            errorMessage = "Configure metadata access in Settings first."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let client = MetadataClient(mode: mode)
            async let movieResults = client.discoverMovies(genreId: genre.id, kind: .movie)
            async let tvResults = client.discoverMovies(genreId: genre.id, kind: .tv)
            movies = (try? await movieResults) ?? []
            shows = (try? await tvResults) ?? []
            _ = try await movieResults
            _ = try await tvResults
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }
            MetadataErrorLogger.record(error, context: "Genre results")
            if movies.isEmpty && shows.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }
}
