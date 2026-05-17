import CoreMetadata
import CoreStorage
import DesignSystem
import SwiftData
import SwiftUI

struct SearchView: View {
    @Environment(AppRouter.self) private var router
    @Query private var settings: [AppSettings]

    @State private var results: [Movie] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)]

    var body: some View {
        ZStack {
            // 1. Categories Grid ScrollView (Permanently mounted to preserve scroll state)
            ScrollView {
                categoriesGrid
                    .padding(.horizontal, 28)
                    .padding(.top, 54)
                    .padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .opacity(router.selectedGenre == nil && router.searchQuery.isEmpty ? 1 : 0)
            .allowsHitTesting(router.selectedGenre == nil && router.searchQuery.isEmpty)
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: router.selectedGenre)
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: router.searchQuery)

            // 2. Genre Results ScrollView
            if let genre = router.selectedGenre, router.searchQuery.isEmpty {
                ScrollView {
                    GenreResultsView(genre: genre) { router.selectedGenre = nil }
                        .padding(.horizontal, 28)
                        .padding(.top, 54)
                        .padding(.bottom, 40)
                }
                .ignoresSafeArea(edges: .top)
                .transition(.opacity)
            }

            // 3. Search Results ScrollView
            if !router.searchQuery.isEmpty {
                ScrollView {
                    searchResultsSection
                        .padding(.horizontal, 28)
                        .padding(.top, 54)
                        .padding(.bottom, 40)
                }
                .ignoresSafeArea(edges: .top)
                .transition(.opacity)
            }
        }
        .onChange(of: router.searchQuery) { _, newValue in
            if newValue.isEmpty {
                results = []
            } else {
                Task { await search() }
            }
        }
    }

    private var categoriesGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Browse by Category")
                .font(MovieBoxTypography.title)
                .padding(.top, 4)

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(GenreCard.movieGenres) { genre in
                    GenreCardView(genre: genre) {
                        router.selectedGenre = genre
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        if isSearching && results.isEmpty {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 220)
        } else if let errorMessage {
            RetryCard(message: errorMessage) {
                Task { await search() }
            }
        } else if results.isEmpty {
            ContentUnavailableView.search(text: router.searchQuery)
                .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Search Results")
                    .font(MovieBoxTypography.title)

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(results) { movie in
                        MoviePosterCard(
                            title: movie.title,
                            subtitle: movie.releaseDate,
                            posterURL: MetadataClient().imageURL(path: movie.posterPath)
                        ) {
                            router.showDetail(id: movie.id, kind: router.detailKind)
                        }
                    }
                }
            }
        }
    }

    private func search() async {
        guard let mode = resolveMetadataMode(from: settings) else {
            errorMessage = "Configure metadata access in Settings first."
            return
        }
        isSearching = true
        errorMessage = nil
        do {
            let client = MetadataClient(mode: mode)
            let rawResults = try await client.searchMovies(query: router.searchQuery, kind: router.detailKind)
            let q = router.searchQuery.lowercased()
            results = rawResults.sorted { m1, m2 in
                let d1 = levenshteinDistance(m1.title.lowercased(), q)
                let d2 = levenshteinDistance(m2.title.lowercased(), q)
                return d1 < d2
            }
        } catch {
            LogStore.shared.log("Error searching movies: \(error)")
            LogStore.shared.log("Stack Trace:\n\(Thread.callStackSymbols.prefix(8).joined(separator: "\n"))")
            errorMessage = error.localizedDescription
        }
        isSearching = false
    }

    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let empty = [Int](repeating: 0, count: s2.count + 1)
        var last = [Int](0...s2.count)
        var current = empty

        for (i, char1) in s1.enumerated() {
            current[0] = i + 1
            for (j, char2) in s2.enumerated() {
                if char1 == char2 {
                    current[j + 1] = last[j]
                } else {
                    current[j + 1] = Swift.min(
                        last[j] + 1,
                        Swift.min(
                            last[j + 1] + 1,
                            current[j] + 1
                        )
                    )
                }
            }
            last = current
            current = empty
        }
        return last[s2.count]
    }
}
