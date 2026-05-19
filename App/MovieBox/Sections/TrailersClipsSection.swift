import CoreMetadata
import SwiftUI

private enum TrailerClipMetrics {
    static let width: CGFloat = 280
    static let height: CGFloat = 158
}

private enum TrailerClipFilter: String, CaseIterable, Identifiable {
    case trailers = "Trailers"
    case clips = "Clips"

    var id: String { rawValue }
}

struct TrailersClipsSection: View {
    let videos: [MediaVideo]
    let onPlay: (URL) -> Void

    @State private var filter: TrailerClipFilter = .trailers

    private var trailerItems: [MediaVideo] {
        videos.filter(\.isTrailerCategory)
    }

    private var clipItems: [MediaVideo] {
        videos.filter(\.isClipCategory)
    }

    private var visibleItems: [MediaVideo] {
        switch filter {
        case .trailers: trailerItems
        case .clips: clipItems
        }
    }

    private var showsFilter: Bool {
        !trailerItems.isEmpty && !clipItems.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if visibleItems.isEmpty {
                CenteredEmptyState(
                    icon: filter == .trailers ? "play.rectangle" : "film",
                    title: filter == .trailers ? "No Trailers" : "No Clips",
                    description: filter == .trailers
                        ? "No trailers are available for this title yet."
                        : "No clips are available for this title yet.",
                    isLoading: false
                )
                .frame(height: TrailerClipMetrics.height)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(visibleItems) { video in
                            TrailerClipCard(video: video) {
                                guard let url = video.youtubeWatchURL else { return }
                                onPlay(url)
                            }
                        }
                    }
                    .padding(.trailing, 24)
                }
                .scrollIndicators(.hidden)
                .frame(height: TrailerClipMetrics.height)
                .mask(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.75),
                            .init(color: .clear, location: 1),
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "play.rectangle.on.rectangle")
                    .foregroundStyle(.secondary)
                Text("Trailers & Clips")
                    .font(.title3.weight(.semibold))
            }

            Spacer(minLength: 0)

            if showsFilter {
                Picker("Category", selection: $filter) {
                    ForEach(TrailerClipFilter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
        }
        .onAppear {
            if trailerItems.isEmpty, !clipItems.isEmpty {
                filter = .clips
            } else {
                filter = .trailers
            }
        }
    }
}

private struct TrailerClipCard: View {
    let video: MediaVideo
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            ZStack(alignment: .bottomLeading) {
                thumbnail
                    .frame(width: TrailerClipMetrics.width, height: TrailerClipMetrics.height)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.35), .black.opacity(0.88)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(video.displayType.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(video.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    HStack {
                        if video.official {
                            Text("Official")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .padding(12)
            }
            .frame(width: TrailerClipMetrics.width, height: TrailerClipMetrics.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let thumbnailURL = video.thumbnailURL {
            AsyncImage(url: thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(white: 0.12)
            Image(systemName: "play.rectangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }
}
