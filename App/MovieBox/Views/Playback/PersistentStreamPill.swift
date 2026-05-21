import CoreMetadata
import DesignSystem
import MovieBoxCore
import SwiftUI

enum PersistentStreamPillStyle {
    case bottomBar
    case compactPlayer
}

struct PersistentStreamPill: View {
    let item: PersistentPlaybackItem
    let progress: Double
    let statusPhase: String
    let isFailed: Bool
    let style: PersistentStreamPillStyle
    let onOpen: () -> Void
    let onCancel: () -> Void

    @State private var isHovering = false

    private var collapsedWidth: CGFloat {
        style == .compactPlayer ? 300 : 360
    }

    private var expandedWidth: CGFloat {
        style == .compactPlayer ? 340 : 400
    }

    private var basePosterSize: CGFloat {
        style == .compactPlayer ? 32 : 40
    }

    private var activePosterSize: CGFloat {
        guard isHovering else { return basePosterSize }
        return style == .compactPlayer ? 40 : 48
    }

    var body: some View {
        Button(action: onOpen) {
            pillContent
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(item.title), \(statusPhase)")
    }

    private var pillContent: some View {
        HStack(spacing: isHovering ? 12 : 10) {
            poster
                .frame(width: activePosterSize, height: activePosterSize)

            VStack(alignment: .leading, spacing: isHovering ? 4 : 2) {
                titleLine

                hoverMetadata
                    .frame(height: isHovering ? nil : 0, alignment: .top)
                    .clipped()
                    .opacity(isHovering ? 1 : 0)

                Text(statusPhase)
                    .font(.caption2)
                    .foregroundStyle(isFailed ? .red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: 14, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            }
            .frame(
                minWidth: 120,
                maxWidth: (isHovering ? expandedWidth : collapsedWidth) - activePosterSize - 64,
                alignment: .leading
            )

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel stream")
        }
        .padding(.leading, isHovering ? 8 : 6)
        .padding(.trailing, 8)
        .padding(.vertical, isHovering ? 9 : (style == .compactPlayer ? 5 : 6))
        .frame(width: isHovering ? expandedWidth : collapsedWidth)
        .background {
            progressFill
                .clipShape(Capsule(style: .continuous))
        }
        .adaptiveGlass(shape: .capsule, strength: .thick)
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.35),
                            Color.white.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
        }
        .shadow(color: .black.opacity(0.18), radius: style == .compactPlayer ? 10 : 16, y: style == .compactPlayer ? 4 : 8)
        .contentShape(Capsule(style: .continuous))
        .animation(MovieBoxMotion.streamPillHover, value: isHovering)
    }

    private var titleLine: some View {
        HStack(spacing: 5) {
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text("·")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Text(item.qualityLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let episode = item.episodeTitle, !episode.isEmpty, style == .bottomBar {
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(episode)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var hoverMetadata: some View {
        HStack(spacing: 10) {
            Label("\(item.seeders)", systemImage: "arrow.up.circle.fill")
                .foregroundStyle(BadgePalette.seedColor(item.seeders))
            if item.leechers > 0 {
                Label("\(item.leechers)", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.secondary)
            }
            if !item.detailLine.isEmpty {
                Text(item.detailLine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption2)
        .monospacedDigit()
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var progressFill: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width * progress)
            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(width: width, height: proxy.size.height, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .animation(MovieBoxMotion.streamPillProgress, value: progress)
    }

    @ViewBuilder
    private var poster: some View {
        Group {
            if let url = item.posterURL {
                CachedImageView(url: url) {
                    posterPlaceholder
                } content: { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            } else {
                posterPlaceholder
            }
        }
        .clipShape(Circle())
    }

    private var posterPlaceholder: some View {
        Circle()
            .fill(Color.primary.opacity(0.08))
            .overlay {
                Image(systemName: "film")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
    }
}
