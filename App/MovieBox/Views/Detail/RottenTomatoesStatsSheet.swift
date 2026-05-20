import SwiftUI
import CoreMetadata

struct RottenTomatoesStatsSheet: View {
    let stats: RottenTomatoesStats

    @Environment(\.dismiss) private var dismiss

    private var verdict: RottenTomatoesBadge.Verdict {
        RottenTomatoesBadge.Verdict(score: stats.percentage)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                VStack(alignment: .leading, spacing: 8) {
                    Text("Critic reviews")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 0) {
                        statRow(label: "Reviews", value: display(stats.totalReviews))
                        Divider().opacity(0.35)
                        statRow(label: "Fresh", value: display(stats.freshCount))
                        Divider().opacity(0.35)
                        statRow(label: "Rotten", value: display(stats.rottenCount))
                        Divider().opacity(0.35)
                        statRow(
                            label: "Average",
                            value: stats.averageScore.map { String(format: "%.1f / 10", $0) } ?? "—"
                        )
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 300)
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(verdict.rawValue)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 6) {
                Text("\(stats.percentage)%")
                    .font(.largeTitle.bold())
                    .monospacedDigit()
                Text("Tomatometer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(verdict.accessibilityPrefix), \(stats.percentage) percent Tomatometer")

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

    private func statRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.vertical, 6)
    }

    private func display(_ value: Int?) -> String {
        value.map { "\($0)" } ?? "—"
    }
}

#Preview {
    RottenTomatoesStatsSheet(
        stats: RottenTomatoesStats(
            percentage: 91,
            totalReviews: 342,
            freshCount: 311,
            rottenCount: 31,
            averageScore: 8.2
        )
    )
}
