import CoreMetadata
import CorePlayer
import CoreStorage
import CoreStreaming
import CoreTorrent
import MovieBoxCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import DesignSystem

struct DownloadsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppServices.self) private var appServices
    @Environment(PlayerState.self) private var playerState
    @Query private var settings: [AppSettings]
    @Query private var movieRecords: [MovieRecord]

    @State private var magnetInput: String = ""
    @State private var showsMagnetSheet = false
    @State private var showsTorrentFileImporter = false
    @State private var errorMessage: String?
    @State private var isStreaming = false

    private var playback: PlaybackSettings { PlaybackSettings.from(settings.first) }

    /// Apple reference stream — https://developer.apple.com/streaming/examples/
    private let hdrTestStreams: [HDRTestStream] = [
        HDRTestStream(
            id: "apple-adv-dv-atmos",
            title: "Apple Advanced HDR",
            url: "https://devstreaming-cdn.apple.com/videos/streaming/examples/adv_dv_atmos/main.m3u8"
        ),
    ]

    var body: some View {
        DownloadsViewBody(
            downloadManager: appServices.downloadManager,
            router: router,
            playerState: playerState,
            settings: settings,
            movieRecords: movieRecords,
            magnetInput: $magnetInput,
            showsMagnetSheet: $showsMagnetSheet,
            showsTorrentFileImporter: $showsTorrentFileImporter,
            errorMessage: $errorMessage,
            isStreaming: $isStreaming,
            hdrTestStreams: hdrTestStreams,
            playback: playback,
            appServices: appServices
        )
    }
}

private struct DownloadsViewBody: View {
    @ObservedObject var downloadManager: DownloadManager
    @Bindable var router: AppRouter
    @Bindable var playerState: PlayerState
    let settings: [AppSettings]
    let movieRecords: [MovieRecord]
    @Binding var magnetInput: String
    @Binding var showsMagnetSheet: Bool
    @Binding var showsTorrentFileImporter: Bool
    @Binding var errorMessage: String?
    @Binding var isStreaming: Bool
    let hdrTestStreams: [HDRTestStream]
    let playback: PlaybackSettings
    let appServices: AppServices

    private var activeTasks: [DownloadManager.DownloadTask] {
        downloadManager.tasks.filter { $0.state != .completed && $0.state != .failed }
    }

    private var completedTasks: [DownloadManager.DownloadTask] {
        downloadManager.tasks.filter { $0.state == .completed }
    }

    private var failedTasks: [DownloadManager.DownloadTask] {
        downloadManager.tasks.filter { $0.state == .failed }
    }

    var body: some View {
        downloadsScrollContent
            .padding(.top, AppLayout.topBarReservedHeight)
            .navigationTitle("Downloads")
            .sheet(isPresented: $showsMagnetSheet) { magnetSheetContent }
            .fileImporter(
                isPresented: $showsTorrentFileImporter,
                allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data],
                allowsMultipleSelection: false,
                onCompletion: handleTorrentFileImport
            )
            .onAppear {
                TorrentBackendSync.apply(from: settings.first)
                applyPendingMagnetImport()
            }
            .onChange(of: router.pendingMagnetImport) { _, _ in
                applyPendingMagnetImport()
            }
            .onChange(of: settings.first?.useLocalBackend) { _, _ in
                TorrentBackendSync.apply(from: settings.first)
            }
            .onChange(of: settings.first?.proxyBaseURL) { _, _ in
                TorrentBackendSync.apply(from: settings.first)
            }
            .onChange(of: settings.first?.appToken) { _, _ in
                TorrentBackendSync.apply(from: settings.first)
            }
    }

    private var downloadsScrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, MovieBoxLayout.shelfHorizontalInset)
                }

                if downloadManager.tasks.isEmpty, hdrTestStreams.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Download movies from details, or use File → Open Torrent / Magnet Link.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    downloadSections
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var downloadSections: some View {
        VStack(alignment: .leading, spacing: 42) {
            if !activeTasks.isEmpty {
                downloadLandscapeSection(title: "In progress") {
                    ForEach(activeTasks) { task in
                        downloadCard(for: task)
                    }
                }
            }

            if !completedTasks.isEmpty {
                downloadLandscapeSection(title: "Ready to watch") {
                    ForEach(completedTasks) { task in
                        downloadCard(for: task)
                    }
                }
            }

            if !failedTasks.isEmpty {
                downloadLandscapeSection(title: "Failed") {
                    ForEach(failedTasks) { task in
                        downloadCard(for: task)
                    }
                }
            }

            if !hdrTestStreams.isEmpty {
                downloadLandscapeSection(title: "Streaming samples") {
                    ForEach(hdrTestStreams) { stream in
                        DownloadTaskRow(
                            model: .hdrTest(stream),
                            artworkURL: nil,
                            tmdbId: 0,
                            mediaKind: .movie,
                            downloadManager: downloadManager,
                            playback: playback,
                            onWatchHDRTest: playHDRTestStream
                        )
                    }
                }
            }
        }
    }

    private func downloadCard(for task: DownloadManager.DownloadTask) -> some View {
        DownloadTaskRow(
            model: .task(task),
            artworkURL: artworkURL(for: task.tmdbId),
            tmdbId: task.tmdbId,
            mediaKind: MediaKind(storageValue: task.mediaKind) ?? .movie,
            downloadManager: downloadManager,
            playback: playback
        )
    }

    private func downloadLandscapeSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)
                .padding(.horizontal, MovieBoxLayout.shelfHorizontalInset)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    content()
                }
                .padding(.horizontal, MovieBoxLayout.shelfHorizontalInset)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func artworkURL(for tmdbId: Int) -> URL? {
        guard tmdbId != 0,
              let record = movieRecords.first(where: { $0.tmdbId == tmdbId }),
              let path = record.posterPath
        else { return nil }
        return MetadataClient().imageURL(path: path, width: 1280)
    }

    private func playHDRTestStream(_ stream: HDRTestStream) {
        guard let url = URL(string: stream.url) else {
            errorMessage = "Invalid HDR test stream URL."
            return
        }
        errorMessage = nil
        playerState.load(
            url: url,
            title: stream.title,
            movieId: 0,
            subtitleAppearance: playback.appearance,
            subtitleFontSize: playback.fontSize
        )
    }

    private var magnetSheetContent: some View {
        MagnetImportSheet(
            magnetInput: $magnetInput,
            isStreaming: isStreaming,
            errorMessage: $errorMessage,
            onStream: { handleMagnetAction(isDownload: false) },
            onDownload: { handleMagnetAction(isDownload: true) },
            onOpenTorrentFile: { showsTorrentFileImporter = true }
        )
    }

    private func handleTorrentFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            importTorrentFile(url)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func applyPendingMagnetImport() {
        guard let pending = router.consumePendingMagnetImport() else { return }
        magnetInput = MagnetLinkParser.normalize(pending)
        errorMessage = nil
        showsMagnetSheet = true
    }

    private func importTorrentFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            magnetInput = try MagnetImportHandler.magnetURI(fromTorrentFileAt: url)
            errorMessage = nil
            showsMagnetSheet = true
        } catch {
            errorMessage = error.localizedDescription
            showsMagnetSheet = true
        }
    }

    private func handleMagnetAction(isDownload: Bool) {
        let cleanLink = MagnetLinkParser.normalize(magnetInput)

        if cleanLink.hasPrefix("http://") || cleanLink.hasPrefix("https://") {
            guard let url = URL(string: cleanLink) else {
                errorMessage = "Invalid stream URL format."
                return
            }
            errorMessage = nil
            playerState.load(
                url: url,
                title: "Direct stream",
                movieId: 0,
                subtitleAppearance: playback.appearance,
                subtitleFontSize: playback.fontSize
            )
            magnetInput = ""
            showsMagnetSheet = false
            return
        }

        let parsedLink: String
        switch MagnetLinkParser.normalizedMagnetOrHTTP(cleanLink) {
        case .success(let link):
            parsedLink = link
        case .failure:
            errorMessage = "Invalid Magnet URI or info_hash format."
            return
        }

        errorMessage = nil
        let displayName = MagnetURI(from: parsedLink)?.displayName ?? "Torrent"

        guard let torrent = TorrentResult.fromMagnetURI(parsedLink, fallbackTitle: displayName) else {
            errorMessage = "Could not parse magnet link."
            return
        }

        if isDownload {
            downloadManager.startDownload(
                tmdbId: 0,
                title: torrent.title,
                magnetURI: parsedLink,
                quality: torrent.quality.rawValue,
                hdrType: torrent.hdrType?.rawValue,
                infoHash: torrent.infoHash
            )
            magnetInput = ""
            showsMagnetSheet = false
            return
        }

        isStreaming = true
        Task { @MainActor in
            defer { isStreaming = false }
            do {
                try await TorrentPlaybackService.play(
                    request: TorrentPlaybackService.Request(
                        torrent: torrent,
                        movieId: 0,
                        playback: playback
                    ),
                    appServices: appServices,
                    playerState: playerState
                )
                magnetInput = ""
                showsMagnetSheet = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
