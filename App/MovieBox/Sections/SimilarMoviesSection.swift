import SwiftUI
import DesignSystem
import CoreMetadata

struct SimilarMoviesSection: View {
    @Environment(AppRouter.self) private var router
    let movies: [Movie]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Similar Movies")
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)
                .padding(.horizontal, DetailLayoutMetrics.shelfSideInset)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(movies.prefix(12)) { movie in
                        MoviePosterCard(
                            title: movie.title,
                            posterURL: MetadataClient().posterDisplayURL(
                                posterPath: movie.posterPath,
                                backdropPath: movie.backdropPath
                            )
                        ) {
                            router.showDetail(id: movie.id, kind: router.detailKind)
                        }
                    }
                }
                .padding(.horizontal, DetailLayoutMetrics.shelfSideInset)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
