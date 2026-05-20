import CoreMetadata
import DesignSystem
import SwiftUI

struct PersonCreditRow: View {
    let credit: PersonCredit
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                poster
                VStack(alignment: .leading, spacing: 4) {
                    Text(credit.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if !credit.roleLine.isEmpty {
                        Text(credit.roleLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    HStack(spacing: 6) {
                        Text(credit.mediaKind == .movie ? "Movie" : "TV")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        if credit.voteAverage > 0 {
                            Text(String(format: "%.1f", credit.voteAverage))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !credit.displayYear.isEmpty {
                    Text(credit.displayYear)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var poster: some View {
        if let url = MetadataClient().imageURL(path: credit.posterPath, width: 154) {
            CachedImageView(url: url) {
                posterPlaceholder
            } content: { image in
                image.resizable().scaledToFill()
            }
            .frame(width: 56, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            posterPlaceholder
        }
    }

    private var posterPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(white: 0.12))
            .frame(width: 56, height: 84)
            .overlay {
                Image(systemName: credit.mediaKind == .movie ? "film" : "tv")
                    .foregroundStyle(.tertiary)
            }
    }
}
