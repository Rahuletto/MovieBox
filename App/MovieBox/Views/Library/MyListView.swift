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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 14)], spacing: 18) {
                    ForEach(movies, id: \.tmdbId) { movie in
                        Button {
                            router.showDetail(id: movie.tmdbId, kind: movie.mediaKindEnum)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .aspectRatio(2/3, contentMode: .fit)
                                    .overlay {
                                        CachedImageView(url: MetadataClient().imageURL(path: movie.posterPath)) {
                                            Image(systemName: "film.stack")
                                                .font(.system(size: 28))
                                                .foregroundStyle(.secondary)
                                        } content: { image in
                                            image.resizable().scaledToFill()
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                    .overlay(alignment: .bottomTrailing) {
                                        if movie.watchedFraction > 0.05 && movie.watchedFraction < 0.95 {
                                            GlassBadge("\(Int(movie.watchedFraction * 100))%", color: .blue)
                                                .padding(4)
                                        }
                                    }

                                Text(movie.title)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .lineLimit(1)

                                if let lastWatched = movie.lastWatchedAt {
                                    Text(lastWatched, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
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
}
