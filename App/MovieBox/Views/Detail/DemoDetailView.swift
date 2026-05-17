// Demos disabled — see StreamTestCatalog.swift
#if false

import AppKit
import CoreMetadata
import CorePlayer
import DesignSystem
import SwiftUI

// MARK: - Detail (matches MovieDetailView chrome)

struct DemoDetailView: View {
    let item: StreamTestCatalog.Item
    let onBack: () -> Void
    let onPlay: () -> Void

    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            DemoDetailBackdrop(item: item, scrollOffset: scrollOffset)
                .ignoresSafeArea()

            DemoDetailScrollContent(item: item, scrollOffset: $scrollOffset, onPlay: onPlay)

            NavigationHeader(title: nil, onBack: onBack)
        }
        .keyboardShortcut(.cancelAction)
        .onKeyPress(.upArrow) {
            onBack()
            return .handled
        }
    }
}

// MARK: - Poster row (Downloads tab)

struct DemoPosterCard: View {
    let item: StreamTestCatalog.Item
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                poster
                    .frame(width: 150, height: 225)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        LinearGradient(
                            colors: [.clear, Color.black.opacity(0.35)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .shadow(color: Color.black.opacity(0.28), radius: 12, x: 0, y: 5)

                Text(item.title)
                    .font(MovieBoxTypography.caption)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                    .frame(width: 150, alignment: .leading)

                Text(item.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(width: 150, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var poster: some View {
        if let url = item.posterImageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure, .empty:
                    gradientPoster
                @unknown default:
                    gradientPoster
                }
            }
        } else {
            gradientPoster
        }
    }

    @ViewBuilder
    private var gradientPoster: some View {
        switch item.poster {
        case .gradient(let colors, let symbol):
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
            }
        case .image:
            Color(white: 0.12)
        }
    }
}

// MARK: - Backdrop

private struct DemoDetailBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    let item: StreamTestCatalog.Item
    let scrollOffset: CGFloat

    private var fadeColor: Color {
        colorScheme == .dark ? .black : .white
    }

    var body: some View {
        let blurAmount = min(max(-scrollOffset / 20, 0), 32)
        let fadeOpacity = min(max(-scrollOffset / 300, 0), 0.5)

        GeometryReader { geo in
            ZStack {
                fadeColor

                posterLayer(size: geo.size)
                    .blur(radius: blurAmount)

                fadeColor.opacity(fadeOpacity)

                LinearGradient(
                    colors: [.clear, fadeColor.opacity(0.1)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                LinearGradient(
                    colors: [fadeColor.opacity(0.3), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    @ViewBuilder
    private func posterLayer(size: CGSize) -> some View {
        if let url = item.posterImageURL {
            CachedImageView(url: url) {
                fadeColor
            } content: { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }
        } else if case .gradient(let colors, _) = item.poster {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: size.width, height: size.height)
        }
    }
}

// MARK: - Scroll content

private struct DemoDetailScrollContent: View {
    let item: StreamTestCatalog.Item
    @Binding var scrollOffset: CGFloat
    let onPlay: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DemoDetailHeroOverlay(item: item, onPlay: onPlay)

                VStack(alignment: .leading, spacing: 24) {
                    DemoAboutSection(item: item)
                    DemoStreamInfoSection(item: item)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .scrollContentBackground(.hidden)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            -geometry.contentOffset.y
        } action: { _, newOffset in
            scrollOffset = newOffset
        }
        .scrollIndicators(.hidden)
    }
}

private struct DemoDetailHeroOverlay: View {
    let item: StreamTestCatalog.Item
    let onPlay: () -> Void

    static let height: CGFloat = 540

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack {
                DemoDetailHeroHeader(item: item, onPlay: onPlay)
                    .frame(maxWidth: 720, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
    }
}

private struct DemoDetailHeroHeader: View {
    let item: StreamTestCatalog.Item
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.title)
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 8) {
                ForEach(item.tags, id: \.self) { tag in
                    GlassBadge(tag)
                }
                if let hdr = item.hdrType {
                    GlassBadge(hdr.rawValue, color: BadgePalette.hdrColor(label: hdr.rawValue))
                }
            }

            Text(item.tagline)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()
                .frame(height: 6)

            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.white, in: Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct DemoAboutSection: View {
    let item: StreamTestCatalog.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Overview")
                .font(.title3.weight(.semibold))

            Text(item.description)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DemoStreamInfoSection: View {
    let item: StreamTestCatalog.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Stream")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 12) {
                infoRow(title: "Provider") {
                    Link(item.sourceName, destination: item.sourcePageURL)
                        .font(.subheadline)
                }

                infoRow(title: "URL") {
                    Text(item.url.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }

                HStack(spacing: 10) {
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
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder
    private func infoRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

#endif
