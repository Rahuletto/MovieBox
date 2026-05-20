import CoreMetadata
import DesignSystem
import SwiftUI

struct PersonKnownForSection: View {
    @Environment(AppRouter.self) private var router
    let credits: [PersonCredit]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Known for")
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)
                .padding(.horizontal, DetailLayoutMetrics.shelfSideInset)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(credits) { credit in
                        MoviePosterCard(
                            title: credit.title,
                            subtitle: credit.roleLine.isEmpty ? credit.displayYear : "\(credit.displayYear) · \(credit.roleLine)",
                            posterURL: MetadataClient().posterDisplayURL(
                                posterPath: credit.posterPath,
                                backdropPath: credit.backdropPath
                            )
                        ) {
                            router.showDetail(id: credit.id, kind: credit.mediaKind)
                        }
                    }
                }
                .padding(.horizontal, DetailLayoutMetrics.shelfSideInset)
                .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
