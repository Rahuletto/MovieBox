import CoreMetadata
import CoreStorage
import DesignSystem
import MovieBoxCore
import SwiftData
import SwiftUI

struct CatalogView: View {
    @Environment(AppRouter.self) private var router
    @Query private var settings: [AppSettings]

    let kind: MediaKind

    @State private var rows: [MetadataCategory: [Movie]] = [:]
    @State private var errorMessage: String?
    @State private var isLoading = false

    

    var body: some View {
        ZStack {
            // Main content scroll view
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 36) {
                    
                    if isLoading && rows.isEmpty {
                        ProgressView()
                            .controlSize(.large)
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else if rows.values.allSatisfy(\.isEmpty) {
                        ContentUnavailableView(
                            "Nothing here yet",
                            systemImage: kind == .movie ? "film" : "tv",
                            description: Text("Configure metadata access in Settings.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        if let trending = rows[.trending], !trending.isEmpty {
                            HeroCarousel(movies: Array(trending.prefix(5)), kind: kind) { movie in
                                router.showDetail(id: movie.id, kind: kind)
                            }
                            .frame(maxWidth: .infinity)
                        }

                        ForEach(MetadataCategory.allCases) { category in
                            if let items = rows[category], !items.isEmpty {
                                HorizontalMovieRow(title: category.displayTitle(for: kind), items: items) { movie in
                                    MoviePosterCard(
                                        title: movie.title,
                                        subtitle: movie.releaseDate,
                                        posterURL: MetadataClient().imageURL(path: movie.posterPath),
                                            onHover: {
                                            if let mode = MetadataSettings.mode(from: settings) {
                                                Task { await Prefetcher.shared.prefetchDetail(id: movie.id, kind: kind, mode: mode) }
                                            }
                                        }
                                    ) {
                                        router.showDetail(id: movie.id, kind: kind)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 28)
            }
            .blur(radius: errorMessage != nil ? 18 : 0)
            .opacity(rows.isEmpty ? 0 : 1)
            
            // Large loading (if rows is empty)
            if isLoading && rows.isEmpty {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Fixed centered Error card floating on a blurred panel
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
        .task(id: "\(settings.first?.cacheKey ?? "missing")|\(kind.rawValue)") {
            await load()
        }
    }

    private func load() async {
        guard let mode = MetadataSettings.mode(from: settings) else {
            errorMessage = "Open Settings and configure metadata access first."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            rows = try await CatalogLoader.loadRows(mode: mode, kind: kind)
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }
            MetadataErrorLogger.record(error, context: "CatalogView load")
            errorMessage = MetadataErrorLogger.userMessage(
                for: error,
                backendURL: settings.first?.proxyBaseURL
            )
        }
    }
}
