import CoreMetadata
import CoreStorage
import DesignSystem
import Foundation
import SwiftData
import SwiftUI

/// Resolves the configured metadata mode from app settings.
/// Mirrors the private helper in RootView so SearchView can stand alone.
private func resolveMetadataMode(from settings: [AppSettings]) -> MetadataEndpointMode? {
    guard let s = settings.first else { return nil }
    if let url = URL(string: s.proxyBaseURL), !s.proxyBaseURL.isEmpty, !s.appToken.isEmpty {
        return .backend(baseURL: url, appToken: s.appToken)
    }
    if !s.tmdbBearerToken.isEmpty {
        return .direct(tmdbBearerToken: s.tmdbBearerToken, omdbAPIKey: s.omdbAPIKey.isEmpty ? nil : s.omdbAPIKey)
    }
    return nil
}

// MARK: - Genre Catalog

struct GenreCard: Identifiable, Hashable {
    let id: Int
    let name: String
    let symbol: String
    let colors: [Color]

    static let movieGenres: [GenreCard] = [
        .init(id: 28, name: "Action", symbol: "burst.fill",
              colors: [Color(red: 0.90, green: 0.31, blue: 0.18), Color(red: 0.95, green: 0.62, blue: 0.16)]),
        .init(id: 12, name: "Adventure", symbol: "map.fill",
              colors: [Color(red: 0.18, green: 0.55, blue: 0.32), Color(red: 0.82, green: 0.88, blue: 0.22)]),
        .init(id: 16, name: "Animation", symbol: "sparkles",
              colors: [Color(red: 0.40, green: 0.20, blue: 0.85), Color(red: 0.95, green: 0.36, blue: 0.74)]),
        .init(id: 35, name: "Comedy", symbol: "face.smiling.inverse",
              colors: [Color(red: 0.18, green: 0.78, blue: 0.84), Color(red: 0.62, green: 0.92, blue: 0.46)]),
        .init(id: 80, name: "Crime", symbol: "shield.lefthalf.filled",
              colors: [Color(red: 0.42, green: 0.08, blue: 0.12), Color(red: 0.78, green: 0.15, blue: 0.16)]),
        .init(id: 99, name: "Documentary", symbol: "doc.text.image",
              colors: [Color(red: 0.30, green: 0.30, blue: 0.35), Color(red: 0.55, green: 0.55, blue: 0.62)]),
        .init(id: 18, name: "Drama", symbol: "theatermasks.fill",
              colors: [Color(red: 0.14, green: 0.27, blue: 0.55), Color(red: 0.32, green: 0.66, blue: 0.86)]),
        .init(id: 10751, name: "Family", symbol: "person.3.fill",
              colors: [Color(red: 0.96, green: 0.55, blue: 0.32), Color(red: 0.99, green: 0.82, blue: 0.42)]),
        .init(id: 14, name: "Fantasy", symbol: "wand.and.stars",
              colors: [Color(red: 0.32, green: 0.18, blue: 0.62), Color(red: 0.18, green: 0.72, blue: 0.74)]),
        .init(id: 27, name: "Horror", symbol: "moon.stars.fill",
              colors: [Color(red: 0.18, green: 0.06, blue: 0.10), Color(red: 0.92, green: 0.38, blue: 0.12)]),
        .init(id: 10402, name: "Music", symbol: "music.note",
              colors: [Color(red: 0.86, green: 0.26, blue: 0.52), Color(red: 0.96, green: 0.70, blue: 0.28)]),
        .init(id: 9648, name: "Mystery", symbol: "magnifyingglass",
              colors: [Color(red: 0.13, green: 0.16, blue: 0.22), Color(red: 0.35, green: 0.40, blue: 0.52)]),
        .init(id: 10749, name: "Romance", symbol: "heart.fill",
              colors: [Color(red: 0.92, green: 0.38, blue: 0.62), Color(red: 0.96, green: 0.72, blue: 0.80)]),
        .init(id: 878, name: "Sci-Fi", symbol: "globe.americas.fill",
              colors: [Color(red: 0.10, green: 0.20, blue: 0.45), Color(red: 0.40, green: 0.86, blue: 0.95)]),
        .init(id: 53, name: "Thriller", symbol: "bolt.fill",
              colors: [Color(red: 0.20, green: 0.08, blue: 0.32), Color(red: 0.78, green: 0.16, blue: 0.55)]),
        .init(id: 10752, name: "War", symbol: "shield.fill",
              colors: [Color(red: 0.32, green: 0.34, blue: 0.22), Color(red: 0.68, green: 0.62, blue: 0.42)]),
        .init(id: 37, name: "Western", symbol: "sun.max.fill",
              colors: [Color(red: 0.62, green: 0.34, blue: 0.18), Color(red: 0.98, green: 0.78, blue: 0.42)]),
        .init(id: 10770, name: "TV Movie", symbol: "tv.fill",
              colors: [Color(red: 0.18, green: 0.28, blue: 0.42), Color(red: 0.55, green: 0.78, blue: 0.92)])
    ]
}

// MARK: - Search View

struct SearchView: View {
    @Environment(AppRouter.self) private var router
    @Query private var settings: [AppSettings]

    @State private var query = ""
    @State private var results: [Movie] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var selectedGenre: GenreCard?

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if query.isEmpty && selectedGenre == nil {
                    categoriesGrid
                } else if let genre = selectedGenre, query.isEmpty {
                    GenreResultsView(genre: genre) { selectedGenre = nil }
                } else {
                    searchResultsSection
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
        .scrollClipDisabled()
        .safeAreaInset(edge: .top, spacing: 0) {
            searchField
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 14)
                .background {
                    LinearGradient(
                        colors: [
                            Color(nsColor: .windowBackgroundColor),
                            Color(nsColor: .windowBackgroundColor).opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                }
        }
        .onChange(of: query) { _, newValue in
            if newValue.isEmpty {
                results = []
            }
        }
    }

    // MARK: Search Field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Search movies and shows", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .onSubmit { Task { await search() } }

            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }

            if isSearching {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .adaptiveGlass(cornerRadius: 24)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Categories Grid

    private var categoriesGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Browse by Category")
                .font(MovieBoxTypography.title)
                .padding(.top, 4)

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(GenreCard.movieGenres) { genre in
                    GenreCardView(genre: genre) {
                        selectedGenre = genre
                    }
                }
            }
        }
    }

    // MARK: Search Results

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
            } else if results.isEmpty && !isSearching {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                Text("Results for \"\(query)\"")
                    .font(MovieBoxTypography.title)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 170), spacing: 16)], spacing: 22) {
                    ForEach(results) { movie in
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
    }

    // MARK: Logic

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let mode = resolveMetadataMode(from: settings) else {
            errorMessage = "Configure metadata access in Settings first."
            return
        }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            let client = MetadataClient(mode: mode)
            async let movies = client.searchMovies(query: trimmed, kind: .movie)
            async let shows = client.searchMovies(query: trimmed, kind: .tv)
            let combined = try await movies + shows
            var seen = Set<Int>()
            results = combined.filter { seen.insert($0.id).inserted }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Genre Card

private struct GenreCardView: View {
    let genre: GenreCard
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: genre.colors, startPoint: .topLeading, endPoint: .bottomTrailing)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                Image(systemName: genre.symbol)
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.18))
                    .rotationEffect(.degrees(-8))
                    .offset(x: 22, y: -28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .clipped()

                Text(genre.name)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 1)
                    .padding(16)
            }
            .aspectRatio(3/4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(genre.name) category")
    }
}

// MARK: - Genre Results

private struct GenreResultsView: View {
    @Environment(AppRouter.self) private var router
    @Query private var settings: [AppSettings]
    let genre: GenreCard
    let onBack: () -> Void

    @State private var movies: [Movie] = []
    @State private var shows: [Movie] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Button {
                    onBack()
                } label: {
                    Label("Categories", systemImage: "chevron.left")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .adaptiveGlass(cornerRadius: 999)

                Text(genre.name)
                    .font(MovieBoxTypography.display)

                Spacer()
            }

            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
            } else {
                if !movies.isEmpty {
                    sectionGrid(title: "Movies", items: movies, kind: .movie)
                }
                if !shows.isEmpty {
                    sectionGrid(title: "TV Shows", items: shows, kind: .tv)
                }
                if movies.isEmpty && shows.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "film.stack",
                        description: Text("Nothing found for \(genre.name).")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
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
                        posterURL: MetadataClient().imageURL(path: movie.posterPath)
                    ) {
                        router.showDetail(id: movie.id, kind: kind)
                    }
                }
            }
        }
    }

    private func load() async {
        guard let mode = resolveMetadataMode(from: settings) else {
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
            _ = try await movieResults  // surface errors only if both fail
            _ = try await tvResults
        } catch {
            if movies.isEmpty && shows.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }
}
