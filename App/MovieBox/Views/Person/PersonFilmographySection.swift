import CoreMetadata
import DesignSystem
import SwiftUI

struct PersonFilmographySection: View {
    @Environment(AppRouter.self) private var router
    let detail: PersonDetail
    @State private var filter: PersonCreditFilter = .all

    private var filteredCredits: [PersonCredit] {
        detail.credits(filter: filter)
    }

    private let gridColumns = [
        GridItem(.adaptive(minimum: 140, maximum: 170), spacing: 16)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Filmography")
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)
                .padding(.horizontal, DetailLayoutMetrics.shelfSideInset)

            VStack(alignment: .leading, spacing: 8) {
                Text("Category")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("Category", selection: $filter) {
                    ForEach(PersonCreditFilter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, DetailLayoutMetrics.shelfSideInset)

            if filteredCredits.isEmpty {
                Text("No credits in this category.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, DetailLayoutMetrics.shelfSideInset)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 22) {
                    ForEach(filteredCredits) { credit in
                        MoviePosterCard(
                            title: credit.title,
                            subtitle: filmographySubtitle(for: credit),
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
                .padding(.bottom, 4)
            }
        }
    }

    private func filmographySubtitle(for credit: PersonCredit) -> String {
        let year = credit.displayYear
        let kindLabel = credit.mediaKind == .movie ? "Movie" : "TV"
        if credit.voteAverage > 0 {
            let rating = String(format: "%.1f", credit.voteAverage)
            if year.isEmpty {
                return "\(kindLabel) · \(rating)"
            }
            return "\(year) · \(rating)"
        }
        return year.isEmpty ? kindLabel : year
    }
}
