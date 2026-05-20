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

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(credits) { credit in
                        MoviePosterCard(
                            title: credit.title,
                            subtitle: credit.roleLine.isEmpty ? credit.displayYear : "\(credit.displayYear) · \(credit.roleLine)",
                            posterURL: MetadataClient().imageURL(path: credit.posterPath)
                        ) {
                            router.showDetail(id: credit.id, kind: credit.mediaKind)
                        }
                    }
                }
                .padding(.trailing, 100)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
