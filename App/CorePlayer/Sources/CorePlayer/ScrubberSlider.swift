import AppKit
import SwiftUI

/// Playback scrubber with debounced hover preview thumbnails (IINA / QuickTime style).
struct ScrubberSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let formatTime: (Double) -> String
    let thumbnailProvider: (Double, UInt64) async -> (UInt64, NSImage?)

    @State private var hoverTime: Double?
    @State private var hoverNormalizedX: CGFloat = 0
    @State private var hoverImage: NSImage?
    @State private var hoverImageBucket: Int?
    @State private var isLoadingThumbnail = false
    @State private var thumbnailRequestID: UInt64 = 0
    @State private var thumbnailTask: Task<Void, Never>?

    private let previewWidth: CGFloat = 160
    private let previewHeight: CGFloat = 90
    private let trackHeight: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = geometry.size.width
            let percentage = progressFraction(for: trackWidth)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(.white)
                    .frame(width: max(0, trackWidth * percentage), height: trackHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle().inset(by: -12))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    updateHover(at: location.x, trackWidth: trackWidth)
                case .ended:
                    clearHover()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let locationX = max(0, min(gesture.location.x, trackWidth))
                        value = time(at: locationX, trackWidth: trackWidth)
                        updateHover(at: locationX, trackWidth: trackWidth)
                    }
                    .onEnded { _ in
                        clearHover()
                    }
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .overlay(alignment: .top) {
            if let hoverTime {
                GeometryReader { geometry in
                    let trackWidth = geometry.size.width
                    thumbnailPreview(for: hoverTime)
                        .frame(width: previewWidth)
                        .position(
                            x: clampedPreviewX(trackWidth: trackWidth),
                            y: previewHeight / 2 + 8
                        )
                }
                .allowsHitTesting(false)
                .offset(y: -(previewHeight + 20))
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoverTime != nil)
        .onDisappear {
            thumbnailTask?.cancel()
            clearHover()
        }
    }

    @ViewBuilder
    private func thumbnailPreview(for time: Double) -> some View {
        let bucket = Int(max(0, time))

        VStack(spacing: 6) {
            Group {
                if let hoverImage, hoverImageBucket == bucket {
                    Image(nsImage: hoverImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: previewWidth, height: previewHeight)
                        .clipped()
                } else if isLoadingThumbnail {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.black.opacity(0.55))
                        .frame(width: previewWidth, height: previewHeight)
                        .overlay {
                            ProgressView()
                                .controlSize(.small)
                        }
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.black.opacity(0.45))
                        .frame(width: previewWidth, height: previewHeight)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.2), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 12, y: 6)

            Text(formatTime(time))
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.65), in: Capsule())
        }
    }

    private func progressFraction(for trackWidth: CGFloat) -> CGFloat {
        guard trackWidth > 0 else { return 0 }
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((value - range.lowerBound) / span)
    }

    private func time(at locationX: CGFloat, trackWidth: CGFloat) -> Double {
        guard trackWidth > 0 else { return range.lowerBound }
        let relativeX = max(0, min(locationX, trackWidth))
        let fraction = Double(relativeX / trackWidth)
        return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }

    private func updateHover(at locationX: CGFloat, trackWidth: CGFloat) {
        guard trackWidth > 0 else { return }

        let relativeX = max(0, min(locationX, trackWidth))
        let time = time(at: relativeX, trackWidth: trackWidth)
        let bucket = Int(max(0, time))

        hoverTime = time
        hoverNormalizedX = relativeX / trackWidth

        if hoverImageBucket != bucket {
            hoverImage = nil
        }

        thumbnailTask?.cancel()
        isLoadingThumbnail = true

        thumbnailTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }

            thumbnailRequestID &+= 1
            let requestID = thumbnailRequestID

            let result = await thumbnailProvider(time, requestID)
            guard !Task.isCancelled else { return }
            guard result.0 == thumbnailRequestID else { return }
            guard Int(max(0, hoverTime ?? -1)) == bucket else { return }

            isLoadingThumbnail = false
            if let image = result.1 {
                hoverImage = image
                hoverImageBucket = bucket
            } else {
                hoverImage = nil
                hoverImageBucket = nil
            }
        }
    }

    private func clearHover() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        hoverTime = nil
        hoverImage = nil
        hoverImageBucket = nil
        isLoadingThumbnail = false
    }

    private func clampedPreviewX(trackWidth: CGFloat) -> CGFloat {
        let centerX = hoverNormalizedX * trackWidth
        let half = previewWidth / 2
        return min(max(centerX, half + 4), trackWidth - half - 4)
    }
}
