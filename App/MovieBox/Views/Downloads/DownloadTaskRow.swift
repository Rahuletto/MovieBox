import AppKit
import CoreMetadata
import CorePlayer
import CoreStorage
import CoreStreaming
import CoreTorrent
import DesignSystem
import MovieBoxCore
import SwiftData
import SwiftUI

struct HDRTestStream: Identifiable {
    let id: String
    let title: String
    let url: String
}

private enum DownloadLandscapeMetrics {
    /// Same footprint as `FeaturedLandscapeRow` — not full window width.
    static let maxCardWidth: CGFloat = 680
    static let aspectRatio: CGFloat = maxCardWidth / 382
    static let cornerRadius: CGFloat = 14
    static let titleLogoMaxWidth: CGFloat = 320
}

enum DownloadRowModel: Identifiable {
    case task(DownloadManager.DownloadTask)
    case hdrTest(HDRTestStream)

    var id: String {
        switch self {
        case .task(let task):
            task.id.uuidString
        case .hdrTest(let stream):
            stream.id
        }
    }
}

/// Wide cinematic card (“Now In Theatres” size) with How-to-Watch progress + detail badges.
struct DownloadTaskRow: View {
    @Environment(PlayerState.self) private var playerState
    @Environment(\.modelContext) private var modelContext
    @Query private var movieRecords: [MovieRecord]
    let model: DownloadRowModel
    let artworkURL: URL?
    let tmdbId: Int
    let mediaKind: MediaKind
    let downloadManager: DownloadManager
    let playback: PlaybackSettings
    var onWatchHDRTest: ((HDRTestStream) -> Void)?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            artworkLayer

            if showsDownloadProgressOverlay {
                GeometryReader { proxy in
                    Color.white.opacity(0.14)
                        .frame(
                            width: max(0, proxy.size.width * downloadProgressValue),
                            height: proxy.size.height,
                            alignment: .leading
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .animation(.easeInOut(duration: 0.25), value: downloadProgressValue)
            }

            if let watchProgressFraction {
                GeometryReader { proxy in
                    Color.white.opacity(0.22)
                        .frame(
                            width: max(0, proxy.size.width * watchProgressFraction),
                            height: proxy.size.height,
                            alignment: .leading
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.25), .black.opacity(0.82)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 14) {
                badgeRow

                titleBlock

                if let metadataSubtitle {
                    Text(metadataSubtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                }

                if let progressDetail {
                    Text(progressDetail)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }

                actionRow
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .aspectRatio(DownloadLandscapeMetrics.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: DownloadLandscapeMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DownloadLandscapeMetrics.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
    }

    // MARK: - Artwork

    @ViewBuilder
    private var artworkLayer: some View {
        Group {
            switch model {
            case .hdrTest:
                hdrTestArtwork
            case .task:
                if let artworkURL {
                    CachedImageView(url: artworkURL) {
                        artworkPlaceholder
                    } content: { image in
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    }
                    .id(artworkURL)
                } else {
                    artworkPlaceholder
                }
            }
        }
        .opacity(artworkDimmed ? 0.52 : 1)
        .animation(.easeInOut(duration: 0.25), value: artworkDimmed)
    }

    private var hdrTestArtwork: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.14, green: 0.16, blue: 0.34),
                    Color(red: 0.05, green: 0.07, blue: 0.14),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "sparkles.tv")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var artworkPlaceholder: some View {
        ZStack {
            Color.primary.opacity(0.08)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Badges & title

    private var badgeRow: some View {
        HStack(spacing: 6) {
            if showsDownloadedBadge {
                Text("Downloaded")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            resolutionBadge

            if !techKinds.isEmpty {
                MediaTechBadgeRow(kinds: techKinds, context: .hero, size: .list)
            }

            if showsDownloadPercent {
                Text("\(Int(downloadProgressValue * 100))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }

            if let watchStatusLabel {
                Text(watchStatusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            Spacer(minLength: 0)

            if let trailingCaption {
                Text(trailingCaption)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var resolutionBadge: some View {
        if qualityLabel != VideoQuality.p2160.rawValue {
            Text(qualityLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    @ViewBuilder
    private var titleBlock: some View {
        if tmdbId > 0, case .task = model {
            AsyncLogoView(movieId: tmdbId, title: title, kind: mediaKind)
                .frame(maxWidth: DownloadLandscapeMetrics.titleLogoMaxWidth, alignment: .leading)
                .scaleEffect(0.92, anchor: .bottomLeading)
        } else {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: 480, alignment: .leading)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 12) {
            primaryAction
            secondaryActions
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch model {
        case .hdrTest(let stream):
            DownloadWatchButton(title: "Watch", progress: nil) {
                onWatchHDRTest?(stream)
            }
        case .task(let task):
            switch task.state {
            case .completed:
                DownloadWatchButton(title: completedWatchButtonTitle, progress: nil) {
                    watchCompletedTask(task)
                }
            case .downloading:
                DownloadWatchButton(
                    title: "Downloading \(Int(task.progress * 100))%",
                    progress: task.progress
                ) {
                    downloadManager.pauseDownload(taskId: task.id)
                }
            case .paused:
                DownloadWatchButton(
                    title: "Resume",
                    progress: task.progress > 0 ? task.progress : nil
                ) {
                    downloadManager.resumeDownload(taskId: task.id)
                }
            case .failed:
                DownloadWatchButton(title: "Retry", progress: nil) {
                    downloadManager.cancelDownload(taskId: task.id)
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        switch model {
        case .task(let task):
            switch task.state {
            case .paused:
                iconAction(systemImage: "xmark", help: "Cancel") {
                    downloadManager.cancelDownload(taskId: task.id)
                }
            case .completed:
                completedTaskOverflowMenu(task)
            default:
                EmptyView()
            }
        case .hdrTest:
            EmptyView()
        }
    }

    private func iconAction(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(0.9))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func completedTaskOverflowMenu(_ task: DownloadManager.DownloadTask) -> some View {
        Menu {
            if let path = task.outputPath {
                Button {
                    let fileURL = URL(fileURLWithPath: path)
                    NSWorkspace.shared.selectFile(
                        fileURL.path,
                        inFileViewerRootedAtPath: fileURL.deletingLastPathComponent().path
                    )
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
            Button("Remove", role: .destructive) {
                downloadManager.removeCompleted(taskId: task.id)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 22))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Model data

    private var title: String {
        switch model {
        case .task(let task):
            task.title
        case .hdrTest(let stream):
            stream.title
        }
    }

    private var qualityLabel: String {
        switch model {
        case .task(let task):
            task.quality
        case .hdrTest:
            VideoQuality.p2160.rawValue
        }
    }

    private var techKinds: [MediaTechKind] {
        switch model {
        case .task(let task):
            downloadTechKinds(quality: task.quality, hdrType: task.hdrType)
        case .hdrTest:
            [.fourK, .dolbyVision, .dolbyAtmos]
        }
    }

    private var showsDownloadedBadge: Bool {
        if case .task(let task) = model {
            return task.state == .completed
        }
        return false
    }

    private var watchRecord: MovieRecord? {
        guard case .task(let task) = model, task.tmdbId > 0 else { return nil }
        return movieRecords.first(where: { $0.tmdbId == task.tmdbId })
    }

    private var resumePosition: Double? {
        guard case .task(let task) = model else { return nil }
        return WatchProgressStore.resumePosition(for: task.tmdbId, in: movieRecords)
    }

    private var watchProgressFraction: Double? {
        guard case .task(let task) = model, task.state == .completed,
              let record = watchRecord
        else { return nil }
        let fraction = WatchProgressStore.progressFraction(for: record)
        guard fraction > 0.05, fraction < 0.95 else { return nil }
        return fraction
    }

    private var completedWatchButtonTitle: String {
        resumePosition != nil ? "Resume" : "Watch"
    }

    private var watchStatusLabel: String? {
        guard case .task(let task) = model, task.state == .completed,
              let record = watchRecord
        else { return nil }
        if let remaining = WatchProgressStore.timeRemainingLabel(for: record) {
            return remaining
        }
        let fraction = WatchProgressStore.progressFraction(for: record)
        guard fraction > 0.05, fraction < 0.95 else { return nil }
        return "\(Int(fraction * 100))% watched"
    }

    private var showsDownloadProgressOverlay: Bool {
        switch model {
        case .task(let task):
            task.state == .downloading || (task.state == .paused && task.progress > 0)
        case .hdrTest:
            false
        }
    }

    private var artworkDimmed: Bool {
        showsDownloadProgressOverlay
    }

    private var showsDownloadPercent: Bool {
        showsDownloadProgressOverlay && downloadProgressValue > 0
    }

    private var progressDetail: String? {
        switch model {
        case .task(let task):
            if task.state == .failed {
                return "Download failed — try another release"
            }
            if task.state == .downloading, task.peerCount > 0 {
                return "\(task.peerCount) peers connected"
            }
            if task.state == .paused {
                return "Paused"
            }
            return nil
        case .hdrTest:
            return "Apple streaming sample"
        }
    }

    private var trailingCaption: String? {
        switch model {
        case .task(let task):
            if task.state == .downloading, task.speed > 0 {
                return ByteFormatting.speed(task.speed)
            }
            if task.totalBytes > 0 {
                return formattedTotalSize(task.totalBytes)
            }
            return nil
        case .hdrTest:
            return "HLS"
        }
    }

    private var metadataSubtitle: String? {
        switch model {
        case .task(let task):
            var parts: [String] = []
            if task.downloadedBytes > 0, task.totalBytes > 0 {
                parts.append("\(formattedTotalSize(task.downloadedBytes)) of \(formattedTotalSize(task.totalBytes))")
            } else if task.totalBytes > 0 {
                parts.append(formattedTotalSize(task.totalBytes))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .hdrTest:
            return nil
        }
    }

    private var downloadProgressValue: Double {
        switch model {
        case .task(let task):
            min(1, max(0, task.progress))
        case .hdrTest:
            1
        }
    }

    private func formattedTotalSize(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1_073_741_824 {
            return String(format: "%.1f GB", value / 1_073_741_824)
        }
        if value >= 1_048_576 {
            return String(format: "%.1f MB", value / 1_048_576)
        }
        if value >= 1024 {
            return String(format: "%.0f KB", value / 1024)
        }
        return "\(bytes) B"
    }

    private func watchCompletedTask(_ task: DownloadManager.DownloadTask) {
        guard let path = task.outputPath else { return }
        if task.tmdbId > 0 {
            let posterPath = movieRecords.first(where: { $0.tmdbId == task.tmdbId })?.posterPath
            WatchProgressStore.ensurePlaybackRecord(
                tmdbId: task.tmdbId,
                title: task.title,
                mediaKind: MediaKind(storageValue: task.mediaKind) ?? .movie,
                posterPath: posterPath,
                in: modelContext,
                existing: movieRecords
            )
        }
        playerState.load(
            url: URL(fileURLWithPath: path),
            title: task.title,
            movieId: task.tmdbId,
            subtitleAppearance: playback.appearance,
            subtitleFontSize: playback.fontSize,
            resumePosition: WatchProgressStore.resumePosition(for: task.tmdbId, in: movieRecords)
        )
    }
}

// MARK: - Play Now–style primary control

private struct DownloadWatchButton: View {
    private enum Style {
        static let bufferingBackgroundOpacity = 0.6
        static let progressFill = Color.white
    }

    let title: String
    let progress: Double?
    let action: () -> Void

    private var showsProgress: Bool {
        guard let progress else { return false }
        return progress > 0 && progress < 1
    }

    private var fillProgress: Double {
        guard let progress, showsProgress else { return 0 }
        return max(progress, 0.05)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .frame(width: 16, height: 16)

                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(.black)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background { buttonBackground }
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .colorScheme(showsProgress ? .light : .dark)
    }

    @ViewBuilder
    private var buttonBackground: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(
                        Color.white.opacity(
                            showsProgress ? Style.bufferingBackgroundOpacity : 1
                        )
                    )

                if showsProgress {
                    Rectangle()
                        .fill(Style.progressFill)
                        .frame(
                            width: max(0, proxy.size.width * fillProgress),
                            height: proxy.size.height,
                            alignment: .leading
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .animation(MovieBoxMotion.streamPillProgress, value: fillProgress)
                }
            }
        }
    }
}
