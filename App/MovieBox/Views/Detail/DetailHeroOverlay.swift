import CoreMetadata
import SwiftUI

struct DetailHeroOverlay: View {
    let detail: MovieDetail
    let kind: MediaKind
    let techKinds: [MediaTechKind]
    let accessibilityTags: [String]
    let playButtonTitle: String
    let playButtonDisabled: Bool
    let addToMyList: () -> Void
    let onRate: (Float) -> Void
    let onPlayNow: () -> Void
    let onPlayTrailer: () -> Void
    let isPreparingTrailer: Bool
    let currentRating: Float?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                MovieDetailHeader(
                    detail: detail,
                    kind: kind,
                    techKinds: techKinds,
                    accessibilityTags: accessibilityTags,
                    addToMyList: addToMyList,
                    onRate: onRate,
                    onPlayNow: onPlayNow,
                    onPlayTrailer: onPlayTrailer,
                    isPreparingTrailer: isPreparingTrailer,
                    currentRating: currentRating,
                    playButtonTitle: playButtonTitle,
                    playButtonDisabled: playButtonDisabled
                )
                .padding(.horizontal, DetailLayoutMetrics.horizontalPadding)
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: DetailLayoutMetrics.heroHeight)
    }
}
