import AppKit
import CorePlayer
import DesignSystem
import SwiftUI

// MARK: - Grid card

struct DemoStreamCard: View {
    let item: StreamTestCatalog.Item
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                poster
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .clipped()

                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(item.tagline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    FlowLayout(spacing: 6) {
                        ForEach(item.tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.08), in: Capsule())
                        }
                        if let hdr = item.hdrType {
                            Text(hdr.rawValue)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(BadgePalette.hdrColor(label: hdr.rawValue), in: Capsule())
                        }
                    }
                }
                .padding(12)
            }
            .background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                Image(systemName: "info.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                    .padding(10)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var poster: some View {
        switch item.poster {
        case .image(let url):
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    gradientPoster(symbol: "film")
                case .empty:
                    ZStack {
                        Color(white: 0.12)
                        ProgressView()
                    }
                @unknown default:
                    gradientPoster(symbol: "film")
                }
            }
            .overlay {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }

        case .gradient(let colors, let symbol):
            gradientPoster(symbol: symbol, colors: colors)
        }
    }

    private func gradientPoster(symbol: String, colors: [Color]? = nil) -> some View {
        let palette = colors ?? [Color(white: 0.15), Color(white: 0.08)]
        return ZStack {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            LinearGradient(
                colors: [.clear, .black.opacity(0.5)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - Detail sheet

struct DemoDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let item: StreamTestCatalog.Item
    let onPlay: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heroPoster
                        .frame(height: 280)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.title)
                            .font(.title.weight(.bold))

                        Text(item.tagline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        tagRow
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("About")
                            .font(.headline)
                        Text(item.description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    sourceSection
                    streamSection
                }
                .padding(24)
            }

            HStack(spacing: 12) {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    onPlay()
                    dismiss()
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .background(.bar)
        }
        .frame(width: 520)
        .frame(minHeight: 560)
    }

    @ViewBuilder
    private var heroPoster: some View {
        switch item.poster {
        case .image(let url):
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    heroGradient
                }
            }
        case .gradient(let colors, let symbol):
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: symbol)
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }

    private var heroGradient: some View {
        LinearGradient(
            colors: [Color(white: 0.18), Color(white: 0.1)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var tagRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(item.tags, id: \.self) { tag in
                GlassBadge(tag)
            }
            if let hdr = item.hdrType {
                GlassBadge(hdr.rawValue, color: BadgePalette.hdrColor(label: hdr.rawValue))
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source")
                .font(.headline)
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                Link(item.sourceName, destination: item.sourcePageURL)
                    .font(.subheadline)
            }
        }
    }

    private var streamSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stream URL")
                .font(.headline)
            Text(item.url.absoluteString)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
            } label: {
                Label("Copy stream URL", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

// MARK: - Tag flow layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [CGRect] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), frames)
    }
}
