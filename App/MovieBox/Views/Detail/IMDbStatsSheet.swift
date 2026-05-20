import SwiftUI
import CoreMetadata

/// Ratings detail sheet — scrollable content, standard dismiss (X), natural sheet height.
struct IMDbStatsSheet: View {
    let enrichment: MovieEnrichment?
    let tmdbRating: Double

    @Environment(\.dismiss) private var dismiss

    private static let imdbYellow = Color(red: 0.965, green: 0.773, blue: 0.094)
    private static let metascoreGreen = Color(red: 0.0, green: 0.667, blue: 0.333)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if hasRatings {
                    sectionBlock(title: "Scores") {
                        VStack(alignment: .leading, spacing: 0) {
                            if let imdbRating = enrichment?.imdbRating {
                                ratingRow(
                                    title: "IMDb",
                                    titleColor: Self.imdbYellow,
                                    value: imdbRating,
                                    scale: 10
                                )
                                Divider().opacity(0.35)
                            }

                            ratingRow(
                                title: "TMDB",
                                titleColor: .accentColor,
                                value: tmdbRating,
                                scale: 10
                            )

                            if let metascore = enrichment?.metascore {
                                Divider().opacity(0.35)
                                ratingRow(
                                    title: "Metascore",
                                    titleColor: Self.metascoreGreen,
                                    value: Double(metascore),
                                    scale: 100,
                                    integerDisplay: true
                                )
                            }
                        }
                    }

                    Text("TMDB reflects community votes on The Movie Database. IMDb and Metascore are from external catalogs when available.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if hasDetails {
                    sectionBlock(title: "Details") {
                        VStack(alignment: .leading, spacing: 0) {
                            if let votes = enrichment?.imdbVotes {
                                detailRow(label: "IMDb votes", value: formatNumber(votes))
                                Divider().opacity(0.35)
                            }

                            if let director = enrichment?.director, !director.isEmpty {
                                detailRow(label: "Director", value: director)
                                Divider().opacity(0.35)
                            }

                            if let runtime = enrichment?.runtimeMin {
                                detailRow(label: "Runtime", value: "\(runtime) min")
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 320)
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ratings")
                    .font(.title2.bold())
                Text("IMDb & scores")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private func sectionBlock(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                }
        }
    }

    private func ratingRow(
        title: String,
        titleColor: Color,
        value: Double,
        scale: Int,
        integerDisplay: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(titleColor)
            Spacer(minLength: 16)
            HStack(spacing: 4) {
                Text(integerDisplay ? "\(Int(value))" : String(format: "%.1f", value))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                Text("/ \(scale)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 6)
    }

    private var hasRatings: Bool {
        enrichment?.imdbRating != nil || enrichment?.metascore != nil || tmdbRating > 0
    }

    private var hasDetails: Bool {
        enrichment?.imdbVotes != nil
            || !(enrichment?.director?.isEmpty ?? true)
            || enrichment?.runtimeMin != nil
    }

    private func formatNumber(_ num: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: num)) ?? "\(num)"
    }
}

#Preview {
    IMDbStatsSheet(
        enrichment: MovieEnrichment(
            imdbRating: 8.4,
            imdbVotes: 207_175,
            metascore: 77,
            rottenTomatoes: nil,
            rottenTomatoesStats: nil,
            runtimeMin: 156,
            rated: "PG-13",
            released: "20 Mar 2026",
            director: "Phil Lord, Christopher Miller",
            writer: nil,
            actors: nil,
            awards: nil,
            country: nil,
            language: nil,
            boxOffice: nil,
            production: nil,
            genre: nil
        ),
        tmdbRating: 8.6
    )
}
