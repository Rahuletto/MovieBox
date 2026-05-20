import SwiftUI
import CoreMetadata
import DesignSystem

/// Compact Tomatometer card (Apple TV–style) for the Media Information column.
struct RottenTomatoesSection: View {
    let stats: RottenTomatoesStats
    @State private var showSheet = false

    private var verdict: RottenTomatoesBadge.Verdict {
        RottenTomatoesBadge.Verdict(score: stats.percentage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statsList
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { showSheet = true }
        .sheet(isPresented: $showSheet) {
            RottenTomatoesStatsSheet(stats: stats)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tomatometer \(stats.percentage) percent on Rotten Tomatoes")
        .accessibilityAddTraits(.isButton)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Image(verdict.rawValue)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 36, height: 36)

                Text("\(stats.percentage)%")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }

            Text("TOMATOMETER")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.2)
        }
    }

    private var statsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            statRow(label: "Reviews", value: stats.totalReviews.map { "\($0)" })
            statRow(label: "Fresh", value: stats.freshCount.map { "\($0)" })
            statRow(label: "Rotten", value: stats.rottenCount.map { "\($0)" })
            statRow(
                label: "Average",
                value: stats.averageScore.map { String(format: "%.1f", $0) }
            )
        }
    }

    private func statRow(label: String, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value ?? "—")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
    }
}

#Preview {
    RottenTomatoesSection(
        stats: RottenTomatoesStats(
            percentage: 89,
            totalReviews: 235,
            freshCount: 209,
            rottenCount: 26,
            averageScore: 7.5
        )
    )
    .frame(width: 220)
    .padding(32)
}
