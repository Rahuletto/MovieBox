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

struct TorrentSection: View {
    @Environment(PlayerState.self) private var playerState
    @Environment(AppServices.self) private var appServices
    @Query private var settings: [AppSettings]

    let movie: Movie
    let torrents: [TorrentResult]
    let searchDiagnostics: TorrentSearchDiagnostics?
    let isTV: Bool
    var episodeLabel: String? = nil
    let subtitleURL: URL?
    var subtitleAppearance: SubtitleAppearance = .cinematic
    var subtitleFontSize: CGFloat = 20

    private var orchestrator: StreamingOrchestrator { appServices.streamingOrchestrator }
    private var downloadManager: DownloadManager { appServices.downloadManager }
    @State private var currentPage = 0
    @State private var busyTorrentID: UUID?
    @State private var cardErrors: [UUID: String] = [:]
    @State private var errorDismissTasks: [UUID: Task<Void, Never>] = [:]
    @State private var downloadWatchTask: Task<Void, Never>?
    @State private var visibleCardModels: [TorrentCardModel] = []

    private let pageSize = 10

    private var seededTorrents: [TorrentResult] { torrents.filter { $0.seeders > 0 } }
    private var unseededTorrents: [TorrentResult] { torrents.filter { $0.seeders <= 0 } }
    /// Seeded releases only; if none exist, show everything so the section is not empty.
    /// Always sorted by seeders descending so the healthiest releases come first.
    private var displayedTorrents: [TorrentResult] {
        let pool = seededTorrents.isEmpty ? torrents : seededTorrents
        return pool.sorted { $0.seeders > $1.seeders }
    }

    private var pageCount: Int {
        max(1, (displayedTorrents.count + pageSize - 1) / pageSize)
    }

    private var clampedPage: Int {
        min(currentPage, max(0, pageCount - 1))
    }

    private var visibleTorrents: [TorrentResult] {
        let start = clampedPage * pageSize
        guard start < displayedTorrents.count else { return [] }
        return Array(displayedTorrents[start..<min(start + pageSize, displayedTorrents.count)])
    }

    private var pageRangeLabel: String {
        guard !displayedTorrents.isEmpty else { return "" }
        let start = clampedPage * pageSize + 1
        let end = min((clampedPage + 1) * pageSize, displayedTorrents.count)
        return "\(start)–\(end) of \(displayedTorrents.count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if torrents.isEmpty {
                ContentUnavailableView(
                    "No Versions Found",
                    systemImage: "magnifyingglass",
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                if seededTorrents.isEmpty && !unseededTorrents.isEmpty {
                    Text("No seeded releases right now. Unseeded copies may not stream.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TorrentVersionList(
                    models: visibleCardModels,
                    busyTorrentID: busyTorrentID,
                    cardErrors: cardErrors,
                    onStream: { startStream(for: $0) },
                    onDownload: { startDownload(for: $0) },
                    onCopyError: copyError
                )

                paginationBar
            }
        }
        .onAppear {
            TorrentBackendSync.apply(from: settings.first)
            rebuildVisibleCardModels()
        }
        .onChange(of: movie.id) { _, _ in
            currentPage = 0
            rebuildVisibleCardModels()
        }
        .onChange(of: torrents.count) { _, _ in
            currentPage = min(currentPage, max(0, pageCount - 1))
            rebuildVisibleCardModels()
        }
        .onChange(of: clampedPage) { _, _ in rebuildVisibleCardModels() }
        .onChange(of: settings.first?.proxyBaseURL) { _, _ in
            TorrentBackendSync.apply(from: settings.first)
        }
        .onChange(of: settings.first?.appToken) { _, _ in
            TorrentBackendSync.apply(from: settings.first)
        }
    }

    private func rebuildVisibleCardModels() {
        visibleCardModels = visibleTorrents.map(TorrentCardModel.init(torrent:))
    }

    private func startStream(for id: UUID) {
        guard let torrent = visibleTorrents.first(where: { $0.id == id }) else { return }
        startStream(torrent)
    }

    private func startDownload(for id: UUID) {
        guard let torrent = visibleTorrents.first(where: { $0.id == id }) else { return }
        startDownload(torrent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("How to Watch")
                    .font(.headline)
                Spacer()
                if !displayedTorrents.isEmpty {
                    Text(pageRangeLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let episodeLabel {
                Text(episodeLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var paginationBar: some View {
        HStack(spacing: 12) {
            Button {
                currentPage = max(0, clampedPage - 1)
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(clampedPage == 0 || pageCount <= 1)

            Spacer(minLength: 0)

            Text(pageCount > 1 ? "Page \(clampedPage + 1) of \(pageCount)" : " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 100)

            Spacer(minLength: 0)

            Button {
                currentPage = min(pageCount - 1, clampedPage + 1)
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(clampedPage >= pageCount - 1 || pageCount <= 1)
        }
        .frame(height: 36)
        .padding(.top, 4)
        .opacity(pageCount > 1 ? 1 : 0)
        .allowsHitTesting(pageCount > 1)
    }

    private var emptyDescription: String {
        let diagnostics = searchDiagnostics ?? TorrentSearchDiagnostics()
        return diagnostics.emptyListingMessage(title: movie.title, isTV: isTV)
    }

    // MARK: - Actions (single shared session / download manager)

    private func startStream(_ torrent: TorrentResult) {
        busyTorrentID = torrent.id
        clearError(for: torrent.id)

        let playback = PlaybackSettings(
            appearance: subtitleAppearance,
            fontSize: subtitleFontSize
        )

        Task { @MainActor in
            defer {
                withAnimation(MovieBoxMotion.player) {
                    busyTorrentID = nil
                }
            }
            do {
                try await TorrentPlaybackService.play(
                    request: TorrentPlaybackService.Request(
                        torrent: torrent,
                        allTorrents: torrents,
                        movieId: movie.id,
                        subtitleURL: subtitleURL,
                        playback: playback,
                        episodeTitle: episodeLabel
                    ),
                    appServices: appServices,
                    playerState: playerState
                )
            } catch {
                presentError(error.localizedDescription, for: torrent.id)
            }
        }
    }

    private func startDownload(_ torrent: TorrentResult) {
        busyTorrentID = torrent.id
        clearError(for: torrent.id)

        let taskId = downloadManager.startDownload(
            tmdbId: movie.id,
            mediaKind: (isTV ? MediaKind.tv : .movie).storageValue,
            title: torrent.title,
            magnetURI: torrent.magnetURI,
            quality: torrent.quality.rawValue,
            hdrType: torrent.hdrType?.rawValue
        )

        downloadWatchTask?.cancel()
        downloadWatchTask = Task {
            await watchDownload(taskId: taskId, torrentID: torrent.id)
        }
    }

    private func watchDownload(taskId: UUID, torrentID: UUID) async {
        while !Task.isCancelled, busyTorrentID == torrentID {
            guard let task = downloadManager.tasks.first(where: { $0.id == taskId }) else {
                await MainActor.run { busyTorrentID = nil }
                return
            }
            switch task.state {
            case .downloading where task.totalBytes > 0:
                await MainActor.run { busyTorrentID = nil }
                return
            case .completed, .paused:
                await MainActor.run { busyTorrentID = nil }
                return
            case .failed:
                await MainActor.run {
                    busyTorrentID = nil
                    presentError("Download failed for this release.", for: torrentID)
                }
                return
            case .downloading, .queued:
                break
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func presentError(_ message: String, for id: UUID) {
        errorDismissTasks[id]?.cancel()
        cardErrors[id] = message
        errorDismissTasks[id] = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                cardErrors.removeValue(forKey: id)
                errorDismissTasks.removeValue(forKey: id)
            }
        }
    }

    private func clearError(for id: UUID) {
        errorDismissTasks[id]?.cancel()
        errorDismissTasks.removeValue(forKey: id)
        cardErrors.removeValue(forKey: id)
    }

    private func copyError(for id: UUID) {
        guard let message = cardErrors[id] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
    }
}

// MARK: - Lightweight display model (computed once per torrent)

private struct TorrentCardModel: Identifiable, Hashable {
    let id: UUID
    let source: String
    let quality: String
    let techKinds: [MediaTechKind]
    let title: String
    let detailLine: String
    let seeders: Int
    let leechers: Int

    init(torrent: TorrentResult) {
        id = torrent.id
        source = torrent.trackerSource.label
        quality = torrent.quality.rawValue
        techKinds = torrentTechKinds(for: torrent)
        title = torrent.title

        var parts: [String] = []
        if torrent.sizeBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: torrent.sizeBytes, countStyle: .file))
        }
        parts.append(torrent.codec.rawValue)
        if torrent.source != .unknown {
            parts.append(torrent.source.rawValue)
        }
        detailLine = parts.joined(separator: " · ")

        seeders = torrent.seeders
        leechers = torrent.leechers
    }
}

// MARK: - macOS inset list (Settings / TV–style rows)

private struct TorrentVersionList: View {
    let models: [TorrentCardModel]
    let busyTorrentID: UUID?
    let cardErrors: [UUID: String]
    let onStream: (UUID) -> Void
    let onDownload: (UUID) -> Void
    let onCopyError: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                TorrentVersionRow(
                    model: model,
                    isBusy: busyTorrentID == model.id,
                    errorMessage: cardErrors[model.id],
                    onStream: { onStream(model.id) },
                    onDownload: { onDownload(model.id) },
                    onCopyError: { onCopyError(model.id) }
                )
                .equatable()

                if index < models.count - 1 {
                    Divider()
                        .padding(.leading, 12)
                }
            }
        }
        // Single uniform translucent container — matches Settings.app /
        // inset-grouped list aesthetic instead of alternating row colors
        // which look broken on top of an image backdrop.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct TorrentVersionRow: View, Equatable {
    let model: TorrentCardModel
    let isBusy: Bool
    let errorMessage: String?
    let onStream: () -> Void
    let onDownload: () -> Void
    let onCopyError: () -> Void

    @State private var isHovering = false

    static func == (lhs: TorrentVersionRow, rhs: TorrentVersionRow) -> Bool {
        lhs.model == rhs.model
            && lhs.isBusy == rhs.isBusy
            && lhs.errorMessage == rhs.errorMessage
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    resolutionBadge
                    if !model.techKinds.isEmpty {
                        MediaTechBadgeRow(kinds: model.techKinds, context: .hero, size: .list)
                    }
                }

                Text(model.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                metadataRow

                if let errorMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                        Button("Copy", action: onCopyError)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Button(action: onStream) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Play")

                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Download")
            }
            .frame(width: 64, alignment: .trailing)
            .opacity(isBusy ? 0.35 : 1)
            .overlay {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .disabled(isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var metadataRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.detailLine.isEmpty {
                Text(model.detailLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(BadgePalette.seedColor(model.seeders))
                    Text("\(model.seeders)")
                        .monospacedDigit()
                        .foregroundStyle(BadgePalette.seedColor(model.seeders))
                }

                if model.leechers > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.secondary)
                        Text("\(model.leechers)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Text(model.source)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .font(.caption)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var resolutionBadge: some View {
        if model.quality != VideoQuality.p2160.rawValue {
            Text(model.quality)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

}
