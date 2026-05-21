import DesignSystem
import MovieBoxCore
import SwiftUI

/// Hero Play control with in-button progress and a buffering status popover on hover.
struct PlayNowButton: View {
    private enum Style {
        static let bufferingBackgroundOpacity = 0.6
        static let progressFill = Color.white
    }

    @Environment(AppServices.self) private var appServices

    let movieId: Int
    let title: String
    let isDisabled: Bool
    let onPlay: () -> Void

    @State private var showsStatusPopover = false
    @State private var isHovering = false

    private var playback: PersistentPlaybackController {
        appServices.persistentPlayback
    }

    private var tick: PersistentPlaybackUITick {
        playback.uiTick
    }

    private var isTrackingThisMovie: Bool {
        playback.isBuffering(movieId: movieId)
    }

    private var progress: Double {
        guard tick.movieId == movieId else { return 0 }
        return Double(tick.progressPercent) / 100
    }

    private var fillProgress: Double {
        guard isTrackingThisMovie else { return 0 }
        return max(progress, 0.05)
    }

    private var percentText: String {
        "\(Int(progress * 100))%"
    }

    var body: some View {
        Button(action: onPlay) {
            labelContent
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background { buttonBackground }
                .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .fixedSize(horizontal: true, vertical: false)
        .colorScheme(isTrackingThisMovie ? .light : .dark)
        .popover(isPresented: $showsStatusPopover, arrowEdge: .bottom) {
            PlayNowBufferingPopover(
                phaseLabel: tick.phaseLabel,
                phaseDetail: tick.phaseDetail,
                progress: progress,
                onCancel: {
                    showsStatusPopover = false
                    Task { await appServices.cancelActiveStream() }
                }
            )
        }
        .onHover { hovering in
            isHovering = hovering
            updatePopoverVisibility()
        }
        .onChange(of: isTrackingThisMovie) { _, _ in
            updatePopoverVisibility()
        }
        .help(isTrackingThisMovie ? tick.phaseLabel : title)
    }

    private var labelContent: some View {
        HStack(spacing: 8) {
            Group {
                if isTrackingThisMovie {
                    BufferingSpinnerIcon()
                } else {
                    Image(systemName: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                }
            }
            .frame(width: 16, height: 16)

            Text(buttonLabel)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.black)
        }
        .zIndex(1)
    }

    @ViewBuilder
    private var buttonBackground: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(
                        Color.white.opacity(
                            isTrackingThisMovie ? Style.bufferingBackgroundOpacity : 1
                        )
                    )

                if isTrackingThisMovie {
                    Rectangle()
                        .fill(Style.progressFill)
                        .frame(width: max(0, proxy.size.width * fillProgress), height: proxy.size.height, alignment: .leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .animation(MovieBoxMotion.streamPillProgress, value: fillProgress)
                }
            }
        }
    }

    private func updatePopoverVisibility() {
        showsStatusPopover = isTrackingThisMovie && isHovering
    }

    private var buttonLabel: String {
        if isTrackingThisMovie {
            if tick.phaseLabel.contains("Opening") {
                return "Opening…"
            }
            return "Buffering \(percentText)"
        }
        return title
    }
}

private struct PlayNowBufferingPopover: View {
    let phaseLabel: String
    let phaseDetail: String
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Preparing stream")
                    .font(.headline)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            PlayNowProgressBar(progress: progress)

            VStack(alignment: .leading, spacing: 6) {
                Text(phaseLabel.isEmpty ? "Starting…" : phaseLabel)
                    .font(.subheadline.weight(.semibold))

                if !phaseDetail.isEmpty {
                    Text(phaseDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(16)
        .frame(width: 280)
    }
}

/// Black spinner for the 60% white buffering button (system ProgressView stays white on macOS).
private struct BufferingSpinnerIcon: View {
    var body: some View {
        Image(systemName: "arrow.trianglehead.2.clockwise")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.black)
            .symbolRenderingMode(.monochrome)
            .symbolEffect(.rotate, options: .repeating)
    }
}

private struct PlayNowProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.12))

                Rectangle()
                    .fill(Color.white.opacity(1))
                    .frame(width: max(0, proxy.size.width * max(progress, 0.05)), height: proxy.size.height, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .frame(height: 5)
        .clipShape(Capsule(style: .continuous))
    }
}
