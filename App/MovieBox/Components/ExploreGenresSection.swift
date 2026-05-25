import CoreMetadata
import CoreStorage
import DesignSystem
import MovieBoxCore
import SwiftData
import SwiftUI

/// Horizontal genre carousel for Home — same cards as Search “Browse by Category”.
struct ExploreGenresSection: View {
    @Environment(AppRouter.self) private var router
    @Query private var settings: [AppSettings]

    @State private var genreImages: [Int: URL] = [:]

    private let cardWidth: CGFloat = 148

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Explore Genres")
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)
                .padding(.horizontal, MovieBoxLayout.shelfHorizontalInset)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(GenreCard.movieGenres) { genre in
                        GenreCardView(genre: genre, imageURL: genreImages[genre.id]) {
                            router.selectedGenre = genre
                            router.show(.search)
                        }
                        .frame(width: cardWidth)
                    }
                }
                .padding(.horizontal, MovieBoxLayout.shelfHorizontalInset)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .task(id: settingsKey) {
            genreImages = GenreCard.backdropImageURLs(mode: MetadataSettings.mode(from: settings))
        }
    }

    private var settingsKey: String {
        guard let setting = settings.first else { return "missing" }
        return "\(setting.useLocalBackend)|\(setting.resolvedProxyBaseURL)|\(setting.tmdbBearerToken)"
    }
}
