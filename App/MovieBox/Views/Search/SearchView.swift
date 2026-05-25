import CoreMetadata
import MovieBoxCore
import CoreStorage
import DesignSystem
import SwiftData
import SwiftUI

struct SearchView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [AppSettings]
    @Query(sort: \SearchHistoryRecord.searchedAt, order: .reverse) private var searchHistory: [SearchHistoryRecord]
    @Query(sort: \SearchOpenedRecord.openedAt, order: .reverse) private var searchOpened: [SearchOpenedRecord]

    @State private var results: [Movie] = []
    @State private var resultKinds: [Int: MediaKind] = [:]
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var suggestedQuery: String?
    @State private var genreImages: [Int: URL] = [:]

    private let columns = [
        GridItem(.adaptive(minimum: MoviePosterCard.posterWidth, maximum: 186), spacing: 16)
    ]

    var body: some View {
        ZStack {
            if let genre = router.selectedGenre {
                RadialGradient(
                    colors: genre.colors.map { $0.opacity(0.35) } + [.clear],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 700
                )
                .ignoresSafeArea()
                .transition(.opacity)
            }
            
            // 1. Categories Grid ScrollView (Permanently mounted to preserve scroll state)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !searchHistory.isEmpty {
                        recentSearchesSection
                    }
                    if !searchOpened.isEmpty {
                        searchedForSection
                    }
                    categoriesGrid
                }
                .padding(.horizontal, 28)
                .padding(.top, 54)
                .padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .opacity(router.selectedGenre == nil && router.searchQuery.isEmpty ? 1 : 0)
            .allowsHitTesting(router.selectedGenre == nil && router.searchQuery.isEmpty)
            .animation(MovieBoxMotion.chrome, value: router.selectedGenre)
            .animation(MovieBoxMotion.chrome, value: router.searchQuery)
            .blur(radius: errorMessage != nil ? 18 : 0)

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
                .blur(radius: errorMessage != nil ? 18 : 0)
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
                .blur(radius: errorMessage != nil ? 18 : 0)
            }

            // 4. Centered Fixed Error Card with ultraThinMaterial blur overlay
            if let errorMessage {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()
                    
                    RetryCard(message: errorMessage) {
                        Task { await search() }
                    }
                    .frame(maxWidth: 420)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: router.searchQuery) { _, newValue in
            searchTask?.cancel()
            suggestedQuery = nil
            if newValue.isEmpty {
                results = []
                isSearching = false
            } else {
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    await search()
                }
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
                    GenreCardView(genre: genre, imageURL: genreImages[genre.id]) {
                        router.selectedGenre = genre
                    }
                }
            }
        }
        .task {
            await loadGenreImages()
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        if isSearching && results.isEmpty {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 220)
        } else if errorMessage != nil {
            Color.clear.frame(height: 1)
        } else if results.isEmpty {
            VStack(spacing: 18) {
                ContentUnavailableView.search(text: router.searchQuery)
                
                if let suggestedQuery {
                    Button(action: {
                        router.searchQuery = suggestedQuery
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .foregroundColor(.yellow)
                            Text("Did you mean:")
                                .foregroundColor(.secondary)
                            Text(suggestedQuery)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Search Results")
                    .font(MovieBoxTypography.title)

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(results) { movie in
                        MoviePosterCard(
                            title: movie.title,
                            posterURL: MetadataClient().posterDisplayURL(
                                posterPath: movie.posterPath,
                                backdropPath: movie.backdropPath
                            )
                        ) {
                            openSearchResult(movie, kind: resultKinds[movie.id] ?? .movie)
                        }
                    }
                }
            }
        }
    }

    private func search() async {
        guard let mode = MetadataSettings.mode(from: settings) else {
            errorMessage = "Configure metadata access in Settings first."
            return
        }
        isSearching = true
        errorMessage = nil
        do {
            let client = MetadataClient(mode: mode)
            let query = router.searchQuery
            async let movies = client.searchMovies(query: query, kind: .movie)
            async let tv = client.searchMovies(query: query, kind: .tv)
            let movieResults = try await movies
            let tvResults = try await tv
            
            guard !Task.isCancelled else { return }
            
            var kinds: [Int: MediaKind] = [:]
            movieResults.forEach { kinds[$0.id] = .movie }
            tvResults.forEach { kinds[$0.id] = .tv }
            
            let combined = movieResults + tvResults
            let q = query.lowercased()
            
            var finalResults = combined
            var suggestion: String? = nil
            
            if combined.isEmpty {
                let cachedMovies = await MovieRegistry.shared.allMovies()
                if !cachedMovies.isEmpty {
                    let (fuzzyMatches, bestSuggestion) = await Task.detached(priority: .userInitiated) { () -> ([Movie], String?) in
                        var matches: [(movie: Movie, dist: Int)] = []
                        var bestMovie: Movie?
                        var minDistance = Int.max
                        
                        for movie in cachedMovies {
                            let title = movie.title.lowercased()
                            guard !title.isEmpty else { continue }
                            let dist = SearchView.levenshteinDistance(title, q)
                            
                            // Collect any movies within distance <= 3 and <= half the title's length
                            if dist <= 3 && dist <= title.count / 2 {
                                matches.append((movie, dist))
                                if dist < minDistance {
                                    minDistance = dist
                                    bestMovie = movie
                                }
                            }
                        }
                        
                        let sortedFuzzy = matches.sorted(by: { $0.dist < $1.dist }).map { $0.movie }
                        return (sortedFuzzy, bestMovie?.title)
                    }.value
                    
                    finalResults = fuzzyMatches
                    suggestion = bestSuggestion
                    
                    // For any fuzzy matches, retrieve their kinds from the registry
                    for match in fuzzyMatches {
                        if let kind = await MovieRegistry.shared.kind(for: match.id) {
                            kinds[match.id] = kind
                        }
                    }
                }
            } else {
                finalResults = await Task.detached(priority: .userInitiated) {
                    return combined.sorted { m1, m2 in
                        let d1 = SearchView.levenshteinDistance(m1.title.lowercased(), q)
                        let d2 = SearchView.levenshteinDistance(m2.title.lowercased(), q)
                        return d1 < d2
                    }
                }.value
            }
            
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                self.resultKinds = kinds
                self.results = finalResults
                self.suggestedQuery = suggestion
            }
        } catch {
            if Task.isCancelled { return }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }
            MetadataErrorLogger.record(error, context: "Search")
            errorMessage = error.localizedDescription
        }
        isSearching = false
    }

    private nonisolated static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
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

    private var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Searches")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button(action: clearAllHistory) {
                    Text("Clear All")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(searchHistory.prefix(8)) { item in
                        HStack(spacing: 6) {
                            Text(item.query)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.primary)
                            
                            Button(action: { deleteHistoryItem(item) }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .padding(4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, 6)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                        )
                        .overlay(
                            Capsule()
                                .stroke(.white.opacity(0.08), lineWidth: 0.5)
                        )
                        .onTapGesture {
                            router.searchQuery = item.query
                        }
                    }
                }
            }
        }
    }

    private var searchedForSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Searched For")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: clearAllOpened) {
                    Text("Clear All")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(searchOpened.prefix(12)) { item in
                        MoviePosterCard(
                            title: item.title,
                            posterURL: MetadataClient().posterDisplayURL(
                                posterPath: item.posterPath,
                                backdropPath: item.backdropPath
                            )
                        ) {
                            router.showDetail(id: item.tmdbId, kind: item.mediaKindEnum)
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func openSearchResult(_ movie: Movie, kind: MediaKind) {
        commitCurrentSearch()
        SearchOpenedStore.save(
            movie: movie,
            kind: kind,
            query: router.searchQuery,
            in: modelContext
        )
        router.showDetail(id: movie.id, kind: kind)
    }

    private func commitCurrentSearch() {
        SearchHistoryStore.save(query: router.searchQuery, in: modelContext)
    }

    private func clearAllHistory() {
        withAnimation {
            for item in searchHistory {
                modelContext.delete(item)
            }
            try? modelContext.save()
        }
    }

    private func clearAllOpened() {
        withAnimation {
            for item in searchOpened {
                modelContext.delete(item)
            }
            try? modelContext.save()
        }
    }

    private func deleteHistoryItem(_ item: SearchHistoryRecord) {
        withAnimation {
            modelContext.delete(item)
            try? modelContext.save()
        }
    }

    private func loadGenreImages() async {
        guard genreImages.isEmpty else { return }
        let resolved = GenreCard.backdropImageURLs(mode: MetadataSettings.mode(from: settings))
        await MainActor.run {
            genreImages = resolved
        }
    }
}
