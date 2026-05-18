import SwiftUI
import CoreMetadata
import DesignSystem

struct MediaInformationSection: View {
    let detail: MovieDetail
    let subtitleLanguages: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            informationColumn
            languagesColumn
            accessibilityColumn
        }
    }

    private var informationColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            columnTitle("Information")

            infoField(
                label: "Released",
                value: detail.enrichment?.released ?? yearFromDate(detail.movie.releaseDate)
            )

            if let rated = detail.enrichment?.rated, !rated.isEmpty {
                infoField(label: "Rated", value: rated)
            }

            if let country = detail.enrichment?.country, !country.isEmpty {
                infoField(label: "Region of Origin", value: country)
            }

            if let director = detail.enrichment?.director, !director.isEmpty {
                infoField(label: "Director", value: director)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var languagesColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            columnTitle("Languages")

            if let language = detail.enrichment?.language, !language.isEmpty {
                infoField(label: "Original Audio", value: language)
            }

            if !subtitleLanguages.isEmpty {
                infoField(
                    label: "Subtitles",
                    value: subtitleLanguages.prefix(8).joined(separator: ", ")
                        + (subtitleLanguages.count > 8 ? ", more" : "")
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            columnTitle("Accessibility")

            accessibilityBlock(
                badge: "SDH",
                description: "Subtitles for the deaf and hard of hearing (SDH) refer to subtitles in the original language with the addition of relevant non-dialogue information."
            )

            accessibilityBlock(
                badge: "AD",
                description: "Audio descriptions (AD) refer to a narration track describing what is happening on screen, to provide context for those who are blind or have low vision."
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func columnTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }

    private func infoField(label: String, value: String?) -> some View {
        Group {
            if let value, !value.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func accessibilityBlock(badge: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MediaOutlineBadge(badge)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func yearFromDate(_ date: String) -> String? {
        let year = date.prefix(4)
        return year.count == 4 ? String(year) : nil
    }
}
