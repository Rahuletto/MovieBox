import CoreMetadata
import SwiftUI

private enum TrailerClipMetrics {
    static let width: CGFloat = 280
    static let height: CGFloat = 158
    static let maxVisible = 12
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
    @State private var resolvedDurations: [String: Int] = [:]

    private var trailerItems: [MediaVideo] {
        Array(MediaVideo.sortedTrailers(videos, durations: resolvedDurations).prefix(TrailerClipMetrics.maxVisible))
    }

    private var clipItems: [MediaVideo] {
        Array(MediaVideo.sortedClips(videos, durations: resolvedDurations).prefix(TrailerClipMetrics.maxVisible))
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
                            TrailerClipCard(
                                video: video,
                                durationSeconds: resolvedDurations[video.key] ?? video.durationSeconds
                            ) {
                                guard let url = video.youtubeWatchURL else { return }
                                onPlay(url)
                            }
                        }
                    }
                    .padding(.trailing, 24)
                }
                .scrollIndicators(.hidden)
                .frame(height: TrailerClipMetrics.height)
            }
        }
        .task(id: videos.map(\.key)) {
            let keys = videos.map(\.key)
            guard !keys.isEmpty else { return }
            resolvedDurations = await YouTubeDurationResolver.durations(for: keys)
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
    let durationSeconds: Int?
    let onPlay: () -> Void

    private var durationLabel: String? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        Button(action: onPlay) {
            ZStack(alignment: .bottomLeading) {
                thumbnail
                    .frame(width: TrailerClipMetrics.width, height: TrailerClipMetrics.height)

                bottomBlurScrim

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(video.displayType.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.75))
                        if let durationLabel {
                            Text(durationLabel)
                                .font(.caption2.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }

                    Text(video.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    HStack {
                        if video.official {
                            Text("Official")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.95))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, 28)
            }
            .frame(width: TrailerClipMetrics.width, height: TrailerClipMetrics.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var bottomBlurScrim: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.35), location: 0.55),
                                .init(color: .black.opacity(0.62), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 118)

                Rectangle()
                    .fill(.thinMaterial)
                    .frame(height: 112)
                    .mask {
                        LinearGradient(
                            stops: cardBottomBlurStops,
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            }
        }
        .allowsHitTesting(false)
    }

    private var cardBottomBlurStops: [Gradient.Stop] {
        (0...20).map { step in
            let t = Double(step) / 20
            let eased = t * t * (3 - 2 * t)
            return .init(color: .black.opacity(eased), location: t)
        }
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
