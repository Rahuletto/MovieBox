import SwiftUI

struct DetailRatingControlsSection: View {
    let currentRating: Float?
    let onRate: (Float) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Your Rating:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button { onRate(-1) } label: {
                        Image(systemName: (currentRating ?? 0) == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle((currentRating ?? 0) == -1 ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dislike (-1)")

                    Button { onRate(1) } label: {
                        Image(systemName: (currentRating ?? 0) == 1 ? "heart.fill" : "heart")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle((currentRating ?? 0) == 1 ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Like (+1)")

                    Button { onRate(2) } label: {
                        Image(systemName: (currentRating ?? 0) == 2 ? "flame.fill" : "flame")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle((currentRating ?? 0) == 2 ? .orange : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Love (+2)")

                    if let currentRating, currentRating != 0 {
                        Button { onRate(0) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear rating")
                    }
                }
                Spacer()
            }
            .padding(12)
        }
    }
}
