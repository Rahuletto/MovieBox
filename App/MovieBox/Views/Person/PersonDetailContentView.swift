import CoreMetadata
import DesignSystem
import SwiftUI

struct PersonDetailContentView: View {
    let detail: PersonDetail?
    let isLoading: Bool
    @Binding var isBiographyExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let detail {
                PersonHeroOverlay(detail: detail, isBiographyExpanded: $isBiographyExpanded)
                    .zIndex(1)

                VStack(alignment: .leading, spacing: 32) {
                    if !detail.knownForCredits.isEmpty {
                        PersonKnownForSection(credits: detail.knownForCredits)
                            .frame(maxWidth: .infinity)
                    }

                    PersonFilmographySection(detail: detail)
                        .frame(maxWidth: .infinity)

                    if detail.externalLinks.hasAny || detail.profile.homepage != nil {
                        PersonExternalLinksSection(profile: detail.profile, links: detail.externalLinks)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, DetailLayoutMetrics.horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ScrollFillingBlurBackground())
            } else if isLoading {
                ProgressView("Loading…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                ContentUnavailableView("Person Not Found", systemImage: "person.crop.circle.badge.questionmark")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PersonHeroOverlay: View {
    let detail: PersonDetail
    @Binding var isBiographyExpanded: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                PersonHeroHeader(profile: detail.profile, isBiographyExpanded: $isBiographyExpanded)
                    .padding(.horizontal, DetailLayoutMetrics.horizontalPadding)
                    .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: DetailLayoutMetrics.heroHeight)
    }
}
