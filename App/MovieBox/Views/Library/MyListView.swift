import CoreMetadata
import CoreStorage
import DesignSystem
import MovieBoxCore
import SwiftData
import SwiftUI

struct MyListView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<MovieRecord> { $0.watchlistAddedAt != nil }, sort: \MovieRecord.watchlistAddedAt, order: .reverse)
    private var movies: [MovieRecord]

    private let columns = [
        GridItem(.adaptive(minimum: MoviePosterCard.posterWidth, maximum: 186), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            if movies.isEmpty {
                ContentUnavailableView(
                    "Your List Is Empty",
                    systemImage: "bookmark",
                    description: Text("Add titles from a movie or show detail page.")
                )
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(movies, id: \.tmdbId) { movie in
                        MoviePosterCard(
                            title: movie.title,
                            posterURL: MetadataClient().posterDisplayURL(posterPath: movie.posterPath, backdropPath: nil),
                            progress: watchProgress(for: movie)
                        ) {
                            router.showDetail(id: movie.tmdbId, kind: movie.mediaKindEnum)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                movie.watchlistAddedAt = nil
                                try? modelContext.save()
                            } label: {
                                Label("Remove from List", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
            }
        }
        .navigationTitle("My List")
    }

    private func watchProgress(for record: MovieRecord) -> Double? {
        let progress = WatchProgressStore.progressFraction(for: record)
        guard progress > 0.05, progress < 0.95 else { return nil }
        return progress
    }
}
