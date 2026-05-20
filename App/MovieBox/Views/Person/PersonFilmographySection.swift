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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Filmography")
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)

            Picker("Category", selection: $filter) {
                ForEach(PersonCreditFilter.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            if filteredCredits.isEmpty {
                Text("No credits in this category.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(filteredCredits) { credit in
                        PersonCreditRow(credit: credit) {
                            router.showDetail(id: credit.id, kind: credit.mediaKind)
                        }
                        if credit.id != filteredCredits.last?.id {
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        }
    }
}
