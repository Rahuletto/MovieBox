import AppKit
import CoreMetadata
import CorePlayer
import CoreStorage
import CoreStreaming
import CoreTorrent
import DesignSystem
import MovieBoxCore
import MovieBoxDetail
import SwiftData
import SwiftUI

struct HDRTestStream: Identifiable {
    let id: String
    let title: String
    let url: String
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

/// Apple TV–style landscape shelf card — same footprint as `FeaturedLandscapeRow`.
struct DownloadTaskRow: View {
    @Environment(AppServices.self) private var appServices
    @Environment(PlayerState.self) private var playerState
    @Environment(\.modelContext) private var modelContext
    @Query private var movieRecords: [MovieRecord]
    @Query private var settings: [AppSettings]
    @State private var bannerArtworkURL: URL?
    let model: DownloadRowModel
    let artworkURL: URL?
    let tmdbId: Int
    let mediaKind: MediaKind
    @ObservedObject var downloadManager: DownloadManager
    let playback: PlaybackSettings
    var onWatchHDRTest: ((HDRTestStream) -> Void)?

    private var resolvedTask: DownloadManager.DownloadTask? {
        guard case .task(let snapshot) = model else { return nil }
        return downloadManager.tasks.first(where: { $0.id == snapshot.id }) ?? snapshot
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            artworkLayer

            LinearGradient(
                colors: [.clear, .black.opacity(0.25), .black.opacity(0.82)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(spacing: 0) {
                topOverlay
                Spacer(minLength: 0)
                shelfBottomContent
            }

            if let watchProgressFraction {
                watchProgressEdgeBar(fraction: watchProgressFraction)
            }

            downloadEdgeProgressBar
        }
        .frame(
            width: MovieBoxLayout.landscapeCardWidth,
            height: MovieBoxLayout.landscapeCardHeight
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: MovieBoxLayout.landscapeCardCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: MovieBoxLayout.landscapeCardCornerRadius,
                style: .continuous
            )
            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
        .task(id: bannerFetchKey) {
            await loadBannerArtwork()
        }
    }

    private var bannerFetchKey: String {
        "\(tmdbId)-\(mediaKind.rawValue)-\(artworkURL?.absoluteString ?? "")"
    }

    private var effectiveArtworkURL: URL? {
        bannerArtworkURL ?? artworkURL
    }

    // MARK: - Shelf layout

    private var topOverlay: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 6) {
                if showsQualityInTopPill {
                    qualityTopPillBadge
                }
                if let pill = topStatusPill {
                    shelfCapsulePill(pill)
                }
            }

            Spacer(minLength: 0)

            if showsTopTrailingControls {
                topTrailingControls
            }
        }
        .padding(14)
    }

    private var showsQualityInTopPill: Bool {
        qualityLabel != VideoQuality.p2160.rawValue
    }

    private var qualityTopPillBadge: some View {
        Text(qualityLabel)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.white.opacity(0.2), in: Capsule())
    }

    private var shelfBottomContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            shelfBadgeRow

            if case .hdrTest(let stream) = model {
                Text(stream.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: MovieBoxLayout.landscapeCardWidth * 0.72, alignment: .leading)
            } else if showsTitleLogo {
                titleBlock
                    .frame(maxWidth: MovieBoxLayout.landscapeLogoMaxWidth, alignment: .leading)
                    .frame(height: 72, alignment: .bottomLeading)
                    .clipped()
            }

            if let statusLine {
                Text(statusLine)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
                    .frame(maxWidth: MovieBoxLayout.landscapeCardWidth * 0.72, alignment: .leading)
            }

            actionRow
        }
        .padding(.horizontal, 20)
        .padding(.bottom, showsDownloadEdgeProgress ? 26 : 18)
    }

    @ViewBuilder
    private var topTrailingControls: some View {
        if let task = resolvedTask {
            HStack(spacing: 8) {
                if canRevealInFinder(task) {
                    shelfIconGlassButton(
                        systemImage: showInFinderSystemImage,
                        help: "Show in Finder"
                    ) {
                        revealDownloadInFinder(task)
                    }
                }

                switch task.state {
                case .completed:
                    EmptyView()
                case .downloading, .queued:
                    shelfGroupedGlassControls {
                        shelfGroupedIconButton(systemImage: "pause.fill", help: "Pause") {
                            downloadManager.pauseDownload(taskId: task.id)
                        }
                        shelfGroupedIconButton(systemImage: "xmark", help: "Cancel download") {
                            downloadManager.cancelDownload(taskId: task.id)
                        }
                    }
                case .paused:
                    shelfGroupedGlassControls {
                        shelfGroupedIconButton(systemImage: "xmark", help: "Cancel download") {
                            downloadManager.cancelDownload(taskId: task.id)
                        }
                    }
                default:
                    EmptyView()
                }
            }
        }
    }

    private func shelfCapsulePill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
    }

    private func shelfIconGlassButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .adaptiveGlass(shape: .roundedRect(cornerRadius: 16), strength: .regular)
        .help(help)
    }

    private func shelfGroupedGlassControls<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 2) {
            content()
        }
        .padding(4)
        .adaptiveGlass(shape: .roundedRect(cornerRadius: 16), strength: .regular)
    }

    private func shelfGroupedIconButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var showInFinderSystemImage: String {
        NSImage(systemSymbolName: "finder", accessibilityDescription: nil) != nil
            ? "finder"
            : "folder"
    }

    private func canRevealInFinder(_ task: DownloadManager.DownloadTask) -> Bool {
        if let path = task.outputPath, !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            return true
        }
        if let dir = task.storageDirectory,
           FileManager.default.fileExists(atPath: dir.path) {
            return true
        }
        return false
    }

    private func revealDownloadInFinder(_ task: DownloadManager.DownloadTask) {
        if let path = task.outputPath, !path.isEmpty {
            let fileURL = URL(fileURLWithPath: path)
            NSWorkspace.shared.selectFile(
                fileURL.path,
                inFileViewerRootedAtPath: fileURL.deletingLastPathComponent().path
            )
            return
        }
        if let dir = task.storageDirectory {
            NSWorkspace.shared.open(dir)
        }
    }

    // MARK: - Edge progress (poster-style, like `MoviePosterCard`)

    @ViewBuilder
    private var downloadEdgeProgressBar: some View {
        if showsDownloadEdgeProgress {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.35))
                        Capsule()
                            .fill(DownloadProgressIcon.activeRingColor)
                            .frame(width: max(4, geo.size.width * downloadProgressValue))
                    }
                }
                .frame(height: 4)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .animation(MovieBoxMotion.streamPillProgress, value: downloadProgressValue)
            }
            .allowsHitTesting(false)
        }
    }

    private func watchProgressEdgeBar(fraction: Double) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Color.white.opacity(0.18)
                .frame(maxWidth: .infinity)
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    Color.white.opacity(0.5)
                        .frame(maxWidth: .infinity)
                        .scaleEffect(x: fraction, y: 1, anchor: .leading)
                }
                .padding(.bottom, showsDownloadEdgeProgress ? 22 : 10)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Artwork

    @ViewBuilder
    private var artworkLayer: some View {
        Group {
            switch model {
            case .hdrTest:
                hdrTestArtwork
            case .task:
                if let effectiveArtworkURL {
                    CachedImageView(url: effectiveArtworkURL) {
                        artworkLoadingPlaceholder
                    } content: { image in
                        image
                            .resizable()
                            .scaledToFill()
                    }
                    .id(effectiveArtworkURL)
                } else {
                    artworkLoadingPlaceholder
                }
            }
        }
        .frame(
            width: MovieBoxLayout.landscapeCardWidth,
            height: MovieBoxLayout.landscapeCardHeight
        )
        .clipped()
        .opacity(artworkDimmed ? 0.72 : 1)
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
        .frame(
            width: MovieBoxLayout.landscapeCardWidth,
            height: MovieBoxLayout.landscapeCardHeight
        )
    }

    private var artworkLoadingPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.primary.opacity(0.14),
                    Color.primary.opacity(0.06),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            ProgressView()
                .controlSize(.regular)
        }
    }

    private var showsTitleLogo: Bool {
        guard case .task = model else { return false }
        return tmdbId > 0
    }

    // MARK: - Badges & title

    private var shelfBadgeRow: some View {
        HStack(spacing: 6) {
            if showsDownloadedBadge {
                GlassBadge("Downloaded", color: MovieBoxColors.success)
            }

            if !techKinds.isEmpty {
                MediaTechBadgeRow(kinds: techKinds, context: .hero, size: .list)
            }

            if let watchStatusLabel {
                GlassBadge(watchStatusLabel, color: MovieBoxColors.accent)
            }

            if case .failed = resolvedTask?.state {
                GlassBadge("Failed", color: MovieBoxColors.danger)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var titleBlock: some View {
        if tmdbId > 0, case .task = model {
            AsyncLogoView(movieId: tmdbId, title: displayTitle, kind: mediaKind)
                .scaleEffect(0.92, anchor: .bottomLeading)
        } else {
            Text(displayTitle)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: 200, alignment: .leading)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 12) {
            primaryAction
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch model {
        case .hdrTest(let stream):
            DownloadPlayPill(
                title: "Watch",
                systemImage: "play.fill",
                showsProgress: false,
                progress: 0,
                isEnabled: true,
                action: { onWatchHDRTest?(stream) }
            )
        case .task:
            taskPrimaryAction
        }
    }

    @ViewBuilder
    private var taskPrimaryAction: some View {
        if let task = resolvedTask {
            switch task.state {
            case .completed:
                if completedFileIsPlayable(task) {
                    DownloadPlayPill(
                        title: completedWatchButtonTitle,
                        systemImage: "play.fill",
                        showsProgress: false,
                        progress: 0,
                        isEnabled: true,
                        action: { watchCompletedTask(task) }
                    )
                } else if !isReexporting {
                    DownloadPlayPill(
                        title: "Fix export",
                        systemImage: "arrow.clockwise",
                        showsProgress: false,
                        progress: 0,
                        isEnabled: true,
                        action: { downloadManager.repairCompletedDownload(taskId: task.id) }
                    )
                }
            case .downloading:
                DownloadPlayPill(
                    title: primaryPillTitle,
                    systemImage: "arrow.down.circle.fill",
                    showsProgress: true,
                    progress: max(downloadProgressValue, 0.05),
                    isEnabled: false,
                    action: {}
                )
            case .queued:
                DownloadPlayPill(
                    title: primaryPillTitle,
                    systemImage: "arrow.down.circle.fill",
                    showsProgress: true,
                    progress: 0.05,
                    isEnabled: false,
                    action: {}
                )
            case .paused:
                DownloadPlayPill(
                    title: "Resume",
                    systemImage: "play.fill",
                    showsProgress: task.progress > 0,
                    progress: task.progress,
                    isEnabled: true,
                    action: { downloadManager.resumeDownload(taskId: task.id) }
                )
            case .failed:
                DownloadPlayPill(
                    title: "Retry",
                    systemImage: "arrow.clockwise",
                    showsProgress: false,
                    progress: 0,
                    isEnabled: true,
                    action: { downloadManager.retryDownload(taskId: task.id) }
                )
            }
        }
    }

    // MARK: - Model data

    private var title: String {
        if let task = resolvedTask { return task.title }
        if case .hdrTest(let stream) = model { return stream.title }
        return ""
    }

    private var displayTitle: String {
        if tmdbId > 0, let record = movieRecords.first(where: { $0.tmdbId == tmdbId }) {
            return record.title
        }
        return title
    }

    private var isReexporting: Bool {
        guard let task = resolvedTask else { return false }
        return downloadManager.isReexporting(taskId: task.id)
    }

    private var primaryPillTitle: String {
        guard let task = resolvedTask else { return "Downloading" }
        switch task.state {
        case .queued:
            return "Starting…"
        case .paused:
            return task.progress > 0 ? "Paused · \(Int(task.progress * 100))%" : "Paused"
        case .downloading:
            if isReexporting {
                return downloadProgressValue > 0
                    ? "Fixing export · \(Int(downloadProgressValue * 100))%"
                    : "Fixing export…"
            }
            if downloadProgressValue > 0 {
                return "Downloading · \(Int(downloadProgressValue * 100))%"
            }
            return "Downloading…"
        default:
            return "Download"
        }
    }

    private var topStatusPill: String? {
        guard let task = resolvedTask else {
            if case .hdrTest = model { return "Sample" }
            return nil
        }
        switch task.state {
        case .downloading:
            if isReexporting {
                return downloadProgressValue > 0
                    ? "Fixing export · \(Int(downloadProgressValue * 100))%"
                    : "Fixing export"
            }
            if let speed = downloadSpeedCaption {
                return downloadProgressValue > 0
                    ? "\(Int(downloadProgressValue * 100))% · \(speed)"
                    : speed
            }
            return downloadProgressValue > 0
                ? "Downloading · \(Int(downloadProgressValue * 100))%"
                : "Downloading"
        case .queued:
            return "Starting"
        case .paused:
            return task.progress > 0 ? "Paused · \(Int(task.progress * 100))%" : "Paused"
        case .failed:
            return "Failed"
        case .completed:
            if !completedFileIsPlayable(task) {
                return "File incomplete"
            }
            return showsDownloadedBadge ? "Ready" : nil
        }
    }

    private var showsTopTrailingControls: Bool {
        guard let task = resolvedTask else { return false }
        switch task.state {
        case .downloading, .queued, .paused:
            return true
        case .completed:
            return canRevealInFinder(task)
        default:
            return false
        }
    }

    private var downloadSpeedCaption: String? {
        guard let task = resolvedTask, task.state == .downloading, task.speed > 0 else { return nil }
        return ByteFormatting.speed(task.speed)
    }

    private var statusLine: String? {
        if let task = resolvedTask {
            if task.state == .failed {
                if let message = task.failureMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !message.isEmpty {
                    return message
                }
                return "Download failed — try another release"
            }

            var parts: [String] = []
            if task.downloadedBytes > 0, task.totalBytes > 0 {
                parts.append("\(formattedTotalSize(task.downloadedBytes)) of \(formattedTotalSize(task.totalBytes))")
            } else if task.totalBytes > 0 {
                parts.append(formattedTotalSize(task.totalBytes))
            }

            if task.state == .downloading, isReexporting {
                parts.append("Rebuilding video file from cached stream…")
            } else if task.state == .downloading, task.peerCount > 0 {
                parts.append("\(task.peerCount) peers")
            } else if task.state == .downloading, task.progress == 0 {
                parts.append("Connecting to peers…")
            } else if task.state == .queued {
                parts.append("Preparing download…")
            } else if task.state == .paused {
                parts.append(task.progress > 0 ? "Paused" : "Waiting to resume")
            } else if task.state == .completed, !completedFileIsPlayable(task) {
                parts.append("Bad export — tap Fix export to rebuild from cached data")
            }

            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        if case .hdrTest = model {
            return "Apple streaming sample"
        }
        return nil
    }

    private var qualityLabel: String {
        if let task = resolvedTask { return task.quality }
        if case .hdrTest = model { return VideoQuality.p2160.rawValue }
        return VideoQuality.p1080.rawValue
    }

    private var techKinds: [MediaTechKind] {
        if let task = resolvedTask {
            return downloadTechKinds(quality: task.quality, hdrType: task.hdrType)
        }
        if case .hdrTest = model {
            return [.fourK, .dolbyVision, .dolbyAtmos]
        }
        return []
    }

    private var showsDownloadedBadge: Bool {
        resolvedTask?.state == .completed
    }

    private var watchRecord: MovieRecord? {
        guard let task = resolvedTask, task.tmdbId > 0 else { return nil }
        return movieRecords.first(where: { $0.tmdbId == task.tmdbId })
    }

    private var watchProgressFraction: Double? {
        guard let task = resolvedTask, task.state == .completed,
              let record = watchRecord
        else { return nil }
        let fraction = WatchProgressStore.progressFraction(for: record)
        guard fraction > 0.05, fraction < 0.95 else { return nil }
        return fraction
    }

    private var completedWatchButtonTitle: String {
        resumePosition != nil ? "Resume" : "Watch"
    }

    private var resumePosition: Double? {
        guard let task = resolvedTask else { return nil }
        return WatchProgressStore.resumePosition(for: task.tmdbId, in: movieRecords)
    }

    private var watchStatusLabel: String? {
        guard let task = resolvedTask, task.state == .completed,
              let record = watchRecord
        else { return nil }
        if let remaining = WatchProgressStore.timeRemainingLabel(for: record) {
            return remaining
        }
        let fraction = WatchProgressStore.progressFraction(for: record)
        guard fraction > 0.05, fraction < 0.95 else { return nil }
        return "\(Int(fraction * 100))% watched"
    }

    private var showsDownloadEdgeProgress: Bool {
        guard let task = resolvedTask else { return false }
        return task.state == .downloading
            || task.state == .queued
            || (task.state == .paused && task.progress > 0)
    }

    private var artworkDimmed: Bool {
        showsDownloadEdgeProgress
    }

    private var downloadProgressValue: Double {
        guard let task = resolvedTask else { return 0 }
        return min(1, max(0, task.progress))
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

    private func loadBannerArtwork() async {
        guard tmdbId > 0, case .task = model else {
            bannerArtworkURL = artworkURL
            return
        }

        let record = movieRecords.first(where: { $0.tmdbId == tmdbId })

        if let mode = MetadataSettings.mode(from: settings) {
            let client = MetadataClient(mode: mode)
            do {
                let detail = try await client.movieDetail(id: tmdbId, kind: mediaKind)
                guard !Task.isCancelled else { return }
                let path = detail.movie.backdropPath
                    ?? detail.movie.posterPath
                    ?? record?.posterPath
                if let path {
                    bannerArtworkURL = client.imageURL(path: path, width: 1280)
                    return
                }
            } catch {
                NSLog(
                    "DownloadTaskRow: banner fetch failed for \(tmdbId) — \(error.localizedDescription)"
                )
            }

            guard !Task.isCancelled else { return }
            if let posterPath = record?.posterPath {
                bannerArtworkURL = client.imageURL(path: posterPath, width: 1280)
                return
            }
        }

        guard !Task.isCancelled else { return }
        bannerArtworkURL = artworkURL
    }

    private func watchCompletedTask(_ task: DownloadManager.DownloadTask) {
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

        let torrent = torrentResult(for: task)
        let kind = mediaKind
        Task { @MainActor in
            let path = appServices.resolvedCompletedMediaPath(for: torrent)
                ?? task.outputPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            guard let path else {
                NSLog("DownloadTaskRow: missing file on disk for task \(task.id)")
                return
            }

            await appServices.prepareForLocalFilePlayback()

            var subtitleCatalog: [SubtitleInfo] = []
            var subtitleSearchContext: SubtitleSearchContext?

            if task.tmdbId > 0,
               let mode = settings.first?.metadataMode {
                do {
                    let client = MetadataClient(mode: mode)
                    let detail = try await client.movieDetail(id: task.tmdbId, kind: kind)
                    subtitleCatalog = await MovieDetailLoader.loadSubtitles(
                        detail: detail,
                        kind: kind,
                        settings: settings.first
                    )
                    subtitleSearchContext = SubtitleSearchContext(
                        title: detail.movie.title,
                        year: Int(detail.movie.releaseDate.prefix(4)),
                        imdbId: detail.imdbId,
                        tmdbId: task.tmdbId,
                        mediaKind: kind,
                        preferredLanguage: settings.first?.preferredSubtitleLang ?? "en",
                        metadataMode: mode
                    )
                } catch {
                    NSLog("Download playback subtitle setup failed: \(error.localizedDescription)")
                }
            }

            appServices.playbackCoordinator.playLocalFile(
                localFilePath: path,
                torrent: torrent,
                allTorrents: [torrent],
                playerState: playerState,
                movieId: task.tmdbId,
                subtitleURL: nil,
                subtitleAppearance: playback.appearance,
                subtitleFontSize: playback.fontSize,
                displayTitle: displayTitle,
                resumePosition: WatchProgressStore.resumePosition(for: task.tmdbId, in: movieRecords),
                posterURL: effectiveArtworkURL
            )
            SubtitlePlaybackSupport.attachToPlayback(
                playerState: playerState,
                catalog: subtitleCatalog,
                searchContext: subtitleSearchContext,
                localMediaPath: path,
                autoSelectRemote: subtitleSearchContext != nil
            )
        }
    }

    private func completedFileIsPlayable(_ task: DownloadManager.DownloadTask) -> Bool {
        guard let path = task.outputPath,
              FileManager.default.fileExists(atPath: path)
        else { return false }
        let url = URL(fileURLWithPath: path)
        guard task.totalBytes > 0 else { return true }
        return (try? TorrentFileAssembler.validateExportedMedia(
            at: url,
            expectedLength: task.totalBytes
        )) != nil
    }

    private func torrentResult(for task: DownloadManager.DownloadTask) -> TorrentResult {
        let lowered = task.title.lowercased()
        let codec: VideoCodec = lowered.contains("x265") || lowered.contains("hevc") ? .h265 : .h264
        let audio: AudioFormat? = lowered.contains("atmos") ? .dolbyAtmos : .aac
        let source: VideoSource = lowered.contains("web-dl") ? .webdl : .webrip
        let magnet = task.magnetURI.isEmpty
            ? "magnet:?xt=urn:btih:\(task.infoHash ?? task.id.uuidString)"
            : task.magnetURI

        return TorrentResult(
            title: task.title,
            magnetURI: magnet,
            quality: VideoQuality(rawValue: task.quality) ?? .p1080,
            hdrType: task.hdrType.flatMap { HDRType(rawValue: $0) },
            codec: codec,
            audioFormat: audio,
            source: source,
            sizeBytes: max(task.totalBytes, 0),
            seeders: 0,
            leechers: 0,
            trackerSource: lowered.contains("yts") ? .yts : .native(site: "MovieBox"),
            infoHash: task.infoHash
        )
    }
}

// MARK: - Play Now–style pill (matches `PlayNowButton`)

private struct DownloadPlayPill: View {
    private enum Style {
        static let activeBackgroundOpacity = 0.6
        static let progressFill = Color.white
    }

    let title: String
    var systemImage: String = "play.fill"
    let showsProgress: Bool
    let progress: Double
    let isEnabled: Bool
    let action: () -> Void

    private var fillProgress: Double {
        guard showsProgress else { return 0 }
        return min(1, max(progress, 0.05))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
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
            .background { pillBackground }
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .fixedSize(horizontal: true, vertical: false)
        .colorScheme(showsProgress ? .light : .dark)
    }

    @ViewBuilder
    private var pillBackground: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(
                        Color.white.opacity(
                            showsProgress ? Style.activeBackgroundOpacity : 1
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
