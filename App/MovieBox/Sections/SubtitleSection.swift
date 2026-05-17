import SwiftUI
import DesignSystem
import CoreMetadata

struct SubtitleSection: View {
    let movie: Movie
    let subtitles: [SubtitleInfo]
    @Binding var selectedSubtitle: SubtitleInfo?
    let isLoading: Bool
    let onSearch: () -> Void
    let onSelect: (SubtitleInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Subtitles")
                    .font(MovieBoxTypography.title)
                    .foregroundStyle(.primary)
                Spacer()
                Button("Search") {
                    onSearch()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else if subtitles.isEmpty {
                Text("No subtitles found. Try searching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(subtitles.prefix(10)) { sub in
                            SubtitleCard(
                                subtitle: sub,
                                isSelected: selectedSubtitle?.id == sub.id,
                                action: { onSelect(sub) }
                            )
                        }
                    }
                    .padding(.trailing, 100)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct SubtitleCard: View {
    let subtitle: SubtitleInfo
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "text.bubble")
                        .foregroundStyle(isSelected ? .green : .secondary)
                    Text(subtitle.language.capitalized)
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                }
                Text(subtitle.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("by \(subtitle.author)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(width: 160)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.green.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.green : Color.secondary.opacity(0.2), lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
