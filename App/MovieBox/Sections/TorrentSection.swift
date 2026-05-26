import AppKit
import Combine
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
    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [AppSettings]
    @Query private var storedMovies: [MovieRecord]
    @Query private var downloads: [DownloadRecord]

    let movie: Movie
    let torrents: [TorrentResult]
    let searchDiagnostics: TorrentSearchDiagnostics?
    var isLoading: Bool = false
    let isTV: Bool
    var episodeLabel: String? = nil
    let subtitleURL: URL?
    var subtitleCatalog: [SubtitleInfo] = []
    var selectedSubtitleID: String? = nil
    var subtitleSearchContext: SubtitleSearchContext? = nil
    var subtitleAppearance: SubtitleAppearance = .cinematic
    var subtitleFontSize: CGFloat = 20

    private var orchestrator: StreamingOrchestrator { appServices.streamingOrchestrator }
    private var downloadManager: DownloadManager { appServices.downloadManager }
    @State private var currentPage = 0
    @State private var sortMode: TorrentSortMode = .seeders
    @State private var streamBusyTorrentID: UUID?
    @State private var rowBufferingByID: [UUID: TorrentRowBufferingSnapshot] = [:]
    @State private var cardErrors: [UUID: String] = [:]
    @State private var errorDismissTasks: [UUID: Task<Void, Never>] = [:]
    @State private var downloadWatchTask: Task<Void, Never>?
    @State private var downloadTaskByTorrentID: [UUID: UUID] = [:]
    @State private var visibleCardModels: [TorrentCardModel] = []

    private let pageSize = 10

    private enum TorrentSortMode: String, CaseIterable, Identifiable {
        case seeders
        case quality
        case fileSize

        var id: String { rawValue }

        var title: String {
            switch self {
            case .seeders: "Seeders"
            case .quality: "Quality"
            case .fileSize: "File Size"
            }
        }
    }

    /// Streamable releases only — hide dead swarms; keep completed local downloads.
    private var watchableTorrents: [TorrentResult] {
        torrents.filter { $0.seeders > 0 || isDownloaded($0) }
    }

    /// Downloaded copies stay pinned to the top, then user-selected sort.
    private var displayedTorrents: [TorrentResult] {
        watchableTorrents.sorted { lhs, rhs in
            let lhsDownloaded = isDownloaded(lhs)
            let rhsDownloaded = isDownloaded(rhs)
            if lhsDownloaded != rhsDownloaded { return lhsDownloaded }

            switch sortMode {
            case .seeders:
                if lhs.seeders != rhs.seeders { return lhs.seeders > rhs.seeders }
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                return lhs.sizeBytes > rhs.sizeBytes
            case .quality:
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                if lhs.seeders != rhs.seeders { return lhs.seeders > rhs.seeders }
                return lhs.sizeBytes > rhs.sizeBytes
            case .fileSize:
                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
                if lhs.seeders != rhs.seeders { return lhs.seeders > rhs.seeders }
                return lhs.quality > rhs.quality
            }
        }
    }

    /// Returns true when the torrent has a completed local download on disk.
    private func isDownloaded(_ torrent: TorrentResult) -> Bool {
        guard let hash = torrent.resolvedInfoHash else { return false }
        let lowerHash = hash.lowercased()
        return downloads.contains {
            $0.infoHash == lowerHash
                && $0.state == DownloadState.completed.rawValue
                && ($0.localFilePath.map { FileManager.default.fileExists(atPath: $0) } ?? false)
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isLoading && torrents.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finding streams…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
            } else if displayedTorrents.isEmpty {
                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Still searching for more…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
                } else {
                    ContentUnavailableView(
                        torrents.isEmpty ? "No Versions Found" : "No Active Seeders",
                        systemImage: torrents.isEmpty ? "magnifyingglass" : "arrow.up.circle",
                        description: Text(
                            torrents.isEmpty
                                ? emptyDescription
                                : "Nothing is seeding right now. Check back later."
                        )
                    )
                    .frame(maxWidth: .infinity, minHeight: 160)
                }
            } else {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Still searching for more…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                TorrentVersionList(
                    models: visibleCardModels,
                    mode: .detail(
                        streamBusyTorrentID: streamBusyTorrentID,
                        bufferingByID: rowBufferingByID,
                        cardErrors: cardErrors,
                        onStream: { startStream(for: $0) },
                        onDownload: { startDownload(for: $0) },
                        onCopyError: copyError
                    )
                )

                paginationBar
            }
        }
        .onAppear {
            TorrentBackendSync.apply(from: settings.first)
            rebuildVisibleCardModels()
            syncStreamRowState(from: appServices.persistentPlayback.uiTick)
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
        .onChange(of: sortMode) { _, _ in
            currentPage = 0
            rebuildVisibleCardModels()
        }
        .onChange(of: downloads.count) { _, _ in rebuildVisibleCardModels() }
        .onReceive(downloadManager.objectWillChange) { _ in
            rebuildVisibleCardModels()
        }
        .onChange(of: settings.first?.proxyBaseURL) { _, _ in
            TorrentBackendSync.apply(from: settings.first)
        }
        .onChange(of: settings.first?.useLocalBackend) { _, _ in
            TorrentBackendSync.apply(from: settings.first)
        }
        .onChange(of: settings.first?.appToken) { _, _ in
            TorrentBackendSync.apply(from: settings.first)
        }
        .onChange(of: appServices.persistentPlayback.uiTick) { _, tick in
            syncStreamRowState(from: tick)
            if tick.movieId == movie.id {
                rebuildVisibleCardModels()
            }
            guard tick.movieId == movie.id,
                  let torrentID = tick.torrentId,
                  tick.phaseLabel == "Failed"
            else { return }
            let message = tick.phaseDetail.isEmpty ? tick.statusLine : tick.phaseDetail
            guard !message.isEmpty else { return }
            presentError(message, for: torrentID)
        }
    }

    private func syncStreamRowState(from tick: PersistentPlaybackUITick) {
        guard tick.isActive, tick.movieId == movie.id, let torrentID = tick.torrentId else {
            guard streamBusyTorrentID != nil || !rowBufferingByID.isEmpty else { return }
            streamBusyTorrentID = nil
            rowBufferingByID = [:]
            return
        }
        let snapshot = tick.rowSnapshot
        if streamBusyTorrentID == torrentID, rowBufferingByID[torrentID] == snapshot {
            return
        }
        streamBusyTorrentID = torrentID
        rowBufferingByID = [torrentID: snapshot]
    }

    private var lastStreamedTorrentID: UUID? {
        guard WatchProgressStore.resumePosition(for: movie.id, in: storedMovies) != nil,
              let hash = storedMovies.first(where: { $0.tmdbId == movie.id })?
                  .lastStreamInfoHash?
                  .lowercased(),
              !hash.isEmpty
        else { return nil }
        return torrents.first(where: { ($0.resolvedInfoHash ?? "").lowercased() == hash })?.id
    }

    private func rebuildVisibleCardModels() {
        let resumeID = lastStreamedTorrentID
        visibleCardModels = visibleTorrents.map { torrent in
            TorrentCardModel(
                torrent: torrent,
                isDownloaded: isDownloaded(torrent),
                showsResumePlay: torrent.id == resumeID,
                downloadActivity: downloadActivity(for: torrent)
            )
        }
    }

    private func activeDownloadTask(for torrent: TorrentResult) -> DownloadManager.DownloadTask? {
        if let taskId = downloadTaskByTorrentID[torrent.id],
           let task = downloadManager.tasks.first(where: { $0.id == taskId }) {
            return task
        }
        if let hash = torrent.resolvedInfoHash?.lowercased(),
           let task = downloadManager.tasks.first(where: { ($0.infoHash ?? "").lowercased() == hash }) {
            return task
        }
        return downloadManager.tasks.first(where: { task in
            task.magnetURI == torrent.magnetURI
                && (task.state == .queued || task.state == .downloading || task.state == .paused)
        })
    }

    private func downloadActivity(for torrent: TorrentResult) -> TorrentDownloadActivity? {
        guard let task = activeDownloadTask(for: torrent) else { return nil }
        switch task.state {
        case .queued:
            return TorrentDownloadActivity(phase: .queued, progress: 0, label: "Starting…")
        case .downloading:
            let percent = task.progress > 0 ? "\(Int(task.progress * 100))%" : "…"
            return TorrentDownloadActivity(
                phase: .downloading,
                progress: task.progress,
                label: "Downloading \(percent)"
            )
        case .paused:
            let percent = task.progress > 0 ? " \(Int(task.progress * 100))%" : ""
            return TorrentDownloadActivity(
                phase: .paused,
                progress: task.progress,
                label: "Paused\(percent)"
            )
        case .completed, .failed:
            return nil
        }
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
                    sortMenu
                }
            }
            if let episodeLabel {
                Text(episodeLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sortMode) {
                ForEach(TorrentSortMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Text("Sort by")
                    .foregroundStyle(.secondary)
                Text(sortMode.title)
                    .fontWeight(.medium)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Sort by")
        .accessibilityValue(sortMode.title)
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
        streamBusyTorrentID = torrent.id
        rowBufferingByID[torrent.id] = .starting
        clearError(for: torrent.id)

        if let localPath = appServices.resolvedCompletedMediaPath(for: torrent, downloadRecords: downloads) {
            Task { @MainActor in
                await playDownloadedFile(at: localPath, torrent: torrent)
            }
            return
        }

        WatchProgressStore.ensureRecord(
            movie: movie,
            kind: isTV ? .tv : .movie,
            genres: movie.genreIds,
            in: modelContext,
            existing: storedMovies
        )

        let playback = PlaybackSettings(
            appearance: subtitleAppearance,
            fontSize: subtitleFontSize
        )
        let posterURL = MetadataClient().posterDisplayURL(
            posterPath: movie.posterPath,
            backdropPath: movie.backdropPath
        )
        let persistentRequest = PersistentPlaybackStartRequest(
            mode: .single(torrent),
            movieId: movie.id,
            mediaKind: isTV ? .tv : .movie,
            allTorrents: torrents,
            posterURL: posterURL,
            title: movie.title,
            episodeTitle: episodeLabel,
            displayTitle: movie.title,
            subtitleURL: subtitleURL,
            subtitleCatalog: subtitleCatalog,
            selectedSubtitleID: selectedSubtitleID,
            subtitleSearchContext: subtitleSearchContext,
            playback: playback,
            resumePosition: WatchProgressStore.resumePosition(for: movie.id, in: storedMovies),
            knownDurationSeconds: movie.runtime.map { Double($0) * 60 },
            onPlaybackOpened: { opened in
                guard let record = storedMovies.first(where: { $0.tmdbId == movie.id }) else { return }
                if let hash = opened.resolvedInfoHash {
                    record.lastStreamInfoHash = hash.lowercased()
                    try? modelContext.save()
                }
            }
        )

        _ = appServices.persistentPlayback.start(
            request: persistentRequest,
            appServices: appServices,
            playerState: playerState
        )
    }

    private func playDownloadedFile(at localPath: String, torrent: TorrentResult) async {
        defer {
            streamBusyTorrentID = nil
            rowBufferingByID = [:]
        }

        await appServices.prepareForLocalFilePlayback()

        WatchProgressStore.ensureRecord(
            movie: movie,
            kind: isTV ? .tv : .movie,
            genres: movie.genreIds,
            in: modelContext,
            existing: storedMovies
        )

        let playback = PlaybackSettings(
            appearance: subtitleAppearance,
            fontSize: subtitleFontSize
        )
        let posterURL = MetadataClient().posterDisplayURL(
            posterPath: movie.posterPath,
            backdropPath: movie.backdropPath
        )

        appServices.playbackCoordinator.playLocalFile(
            localFilePath: localPath,
            torrent: torrent,
            allTorrents: torrents,
            playerState: playerState,
            movieId: movie.id,
            subtitleURL: subtitleURL,
            subtitleAppearance: playback.appearance,
            subtitleFontSize: playback.fontSize,
            episodeTitle: episodeLabel,
            displayTitle: movie.title,
            resumePosition: WatchProgressStore.resumePosition(for: movie.id, in: storedMovies),
            knownDurationSeconds: movie.runtime.map { Double($0) * 60 },
            posterURL: posterURL
        )

        if let context = subtitleSearchContext {
            SubtitlePlaybackSupport.attachToPlayback(
                playerState: playerState,
                catalog: subtitleCatalog,
                searchContext: context,
                selectedSubtitleID: selectedSubtitleID,
                localMediaPath: localPath,
                autoSelectRemote: subtitleURL == nil
            )
        } else if subtitleURL != nil {
            SubtitlePlaybackSupport.attachToPlayback(
                playerState: playerState,
                catalog: subtitleCatalog,
                searchContext: nil,
                selectedSubtitleID: selectedSubtitleID,
                localMediaPath: localPath,
                autoSelectRemote: false
            )
        }

        if let hash = torrent.resolvedInfoHash,
           let record = storedMovies.first(where: { $0.tmdbId == movie.id }) {
            record.lastStreamInfoHash = hash.lowercased()
            try? modelContext.save()
        }
    }

    private func startDownload(_ torrent: TorrentResult) {
        clearError(for: torrent.id)
        TorrentBackendSync.apply(from: settings.first)

        guard DownloadIdentity.resolve(
            magnetURI: torrent.magnetURI,
            storedInfoHash: torrent.infoHash
        ) != nil else {
            presentError("This release has an invalid magnet link.", for: torrent.id)
            return
        }

        let taskId = downloadManager.startDownload(
            tmdbId: movie.id,
            mediaKind: (isTV ? MediaKind.tv : .movie).storageValue,
            title: torrent.title,
            magnetURI: torrent.magnetURI,
            quality: torrent.quality.rawValue,
            hdrType: torrent.hdrType?.rawValue,
            infoHash: torrent.infoHash
        )

        downloadTaskByTorrentID[torrent.id] = taskId
        rebuildVisibleCardModels()

        downloadWatchTask?.cancel()
        downloadWatchTask = Task {
            await watchDownload(taskId: taskId, torrentID: torrent.id)
        }
    }

    private func watchDownload(taskId: UUID, torrentID: UUID) async {
        while !Task.isCancelled {
            guard let task = downloadManager.tasks.first(where: { $0.id == taskId }) else {
                await MainActor.run {
                    downloadTaskByTorrentID.removeValue(forKey: torrentID)
                    rebuildVisibleCardModels()
                }
                return
            }

            await MainActor.run { rebuildVisibleCardModels() }

            switch task.state {
            case .failed:
                await MainActor.run {
                    let detail = task.failureMessage?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let message = (detail?.isEmpty == false)
                        ? detail!
                        : "Download failed for this release."
                    presentError(message, for: torrentID)
                    downloadTaskByTorrentID.removeValue(forKey: torrentID)
                    rebuildVisibleCardModels()
                }
                return
            case .completed:
                await MainActor.run {
                    downloadTaskByTorrentID.removeValue(forKey: torrentID)
                    rebuildVisibleCardModels()
                }
                return
            case .queued, .downloading, .paused:
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
