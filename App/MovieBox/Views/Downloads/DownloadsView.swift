import CorePlayer
import CoreStorage
import CoreStreaming
import CoreTorrent
import MovieBoxCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct DownloadsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppServices.self) private var appServices
    @Environment(PlayerState.self) private var playerState
    @Query private var settings: [AppSettings]

    @State private var magnetInput: String = ""
    @State private var showsMagnetSheet = false
    @State private var showsTorrentFileImporter = false
    @State private var errorMessage: String?
    @State private var isStreaming = false

    private var downloadManager: DownloadManager { appServices.downloadManager }
    private var playback: PlaybackSettings { PlaybackSettings.from(settings.first) }

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
            VStack(spacing: 20) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 28)
                }

                if downloadManager.tasks.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Download movies from details, or use File → Open Torrent / Magnet Link.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(downloadManager.tasks) { task in
                            DownloadTaskRow(
                                task: task,
                                downloadManager: downloadManager,
                                playback: playback
                            )
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                }
            }
        }
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
                hdrType: torrent.hdrType?.rawValue
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
