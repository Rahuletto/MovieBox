import CorePlayer
import CoreStreaming
import CoreStorage
import DesignSystem
import MovieBoxCore
import SwiftData
import SwiftUI

struct AppShellView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PlayerState.self) private var playerState
    @Environment(AppServices.self) private var appServices
    @Environment(AppErrorCenter.self) private var errorCenter
    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [AppSettings]
    @State private var didAttachPersistence = false
    @State private var showsReplaceStreamConfirmation = false
    @Namespace private var streamPillNamespace

    private var persistentPlayback: PersistentPlaybackController {
        appServices.persistentPlayback
    }

    /// Full-screen player blocks browsing (trailers, clips, etc.).
    private var isBrowsingObstructed: Bool {
        playerState.isPresented && !playerState.isPlaybackChromeHidden
    }

    private var streamPillPlacement: StreamPillPlacement {
        guard persistentPlayback.isActive, persistentPlayback.item != nil else { return .hidden }
        if isBrowsingObstructed && !playerState.isStreamingTorrent {
            return .topTrailing
        }
        if !isBrowsingObstructed {
            return .bottom
        }
        return .hidden
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

            RootContentView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .top)
                .opacity(isBrowsingObstructed ? 0 : 1)
                .allowsHitTesting(!isBrowsingObstructed)
                .animation(MovieBoxMotion.player, value: isBrowsingObstructed)
                .animation(MovieBoxMotion.navigation, value: router.selectedRoute)

            RootTabBarChrome()
                .opacity(isBrowsingObstructed ? 0 : 1)
                .allowsHitTesting(!isBrowsingObstructed)
                .animation(MovieBoxMotion.player, value: isBrowsingObstructed)
                .zIndex(5)

            Group {
                if playerState.isPresented {
                    PlayerView(state: playerState) {
                        PlaybackSourcesSidebar(
                            playerState: playerState,
                            torrents: appServices.playbackCoordinator.torrents
                        )
                    } subtitlesSidebar: {
                        PlaybackSubtitlesSidebar(playerState: playerState)
                    } streamStatsAccessory: {
                        if let session = appServices.activeSession {
                            TorrentStreamStatsAccessory(session: session)
                        }
                    }
                    .ignoresSafeArea()
                    .opacity(playerChromeOpacity)
                    .allowsHitTesting(!playerState.isPlaybackChromeHidden && playerState.isPlayerRevealed)
                    .transition(.opacity)
                }
            }
            .animation(MovieBoxMotion.player, value: playerState.isPlaybackChromeHidden)
            .zIndex(10)

            StreamPillLayer(
                placement: streamPillPlacement,
                isVisible: persistentPlayback.isActive,
                namespace: streamPillNamespace,
                onOpen: openStreamPillDestination,
                onCancel: cancelPersistentStream
            )
            .zIndex(12)

            AppSettingsPlaybackSync()
                .allowsHitTesting(false)
        }
        .ignoresSafeArea(edges: .top)
        .background(
            WindowConfigurator(trafficLightInset: CGPoint(x: 24, y: 20), isPlayerPresented: isBrowsingObstructed)
                .frame(width: 0, height: 0)
        )
        .watchHistoryTracking()
        .onAppear {
            TorrentBackendSync.apply(from: settings.first)
        }
        .task {
            AppBootstrap.runInitialSetup(
                modelContext: modelContext,
                errorCenter: errorCenter,
                appServices: appServices,
                didAttachPersistence: &didAttachPersistence
            )
            #if DEBUG
            DevelopmentSettings.applyIfNeeded(modelContext: modelContext)
            #endif
            if let settings = (try? modelContext.fetch(FetchDescriptor<AppSettings>()))?.first {
                if TorrentBackendSync.repairProxySettings(settings) {
                    try? modelContext.save()
                }
                TorrentBackendSync.apply(from: settings)
            }
        }
        .overlay(alignment: .top) {
            AppErrorBanner()
        }
        .onChange(of: persistentPlayback.pendingRequest != nil) { _, hasPending in
            showsReplaceStreamConfirmation = hasPending
        }
        .confirmationDialog(
            "Cancel the current download and start a new one?",
            isPresented: $showsReplaceStreamConfirmation,
            titleVisibility: .visible
        ) {
            Button("Start New", role: .destructive) {
                persistentPlayback.confirmReplaceAndStart(
                    appServices: appServices,
                    playerState: playerState
                )
            }
            Button("Keep Current", role: .cancel) {
                persistentPlayback.dismissPendingRequest()
            }
        }
    }

    private var playerChromeOpacity: Double {
        if playerState.isPlaybackChromeHidden { return 0.001 }
        return playerState.isPlayerRevealed ? 1 : 0
    }

    private func openStreamPillDestination(item: PersistentPlaybackItem) {
        let shouldPiP = playerState.isPresented && !playerState.isStreamingTorrent
        if shouldPiP {
            playerState.minimizeToPictureInPicture()
        }
        Task { @MainActor in
            if shouldPiP {
                try? await Task.sleep(for: .milliseconds(120))
            }
            router.showDetail(id: item.movieId, kind: item.mediaKind)
        }
    }

    private func cancelPersistentStream() {
        Task {
            await appServices.cancelActiveStream()
        }
    }
}

private enum StreamPillPlacement: Equatable {
    case hidden
    case bottom
    case topTrailing

    var alignment: Alignment {
        switch self {
        case .hidden: .center
        case .bottom: .bottom
        case .topTrailing: .topTrailing
        }
    }

    var edgePadding: EdgeInsets {
        switch self {
        case .hidden:
            EdgeInsets()
        case .bottom:
            EdgeInsets(top: 0, leading: 0, bottom: 28, trailing: 0)
        case .topTrailing:
            EdgeInsets(top: 52, leading: 0, bottom: 0, trailing: 20)
        }
    }
}

/// Isolated pill host so `uiTick` progress updates do not relayout the whole shell.
private struct StreamPillLayer: View {
    @Environment(AppServices.self) private var appServices

    let placement: StreamPillPlacement
    let isVisible: Bool
    let namespace: Namespace.ID
    let onOpen: (PersistentPlaybackItem) -> Void
    let onCancel: () -> Void

    private var playback: PersistentPlaybackController {
        appServices.persistentPlayback
    }

    var body: some View {
        Group {
            if isVisible, let item = playback.item, placement != .hidden {
                let tick = playback.uiTick
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: placement.alignment) {
                        PersistentStreamPill(
                            item: item,
                            progress: Double(tick.progressPercent) / 100,
                            statusPhase: pillStatusPhase(tick: tick),
                            isFailed: isPersistentFailed,
                            style: placement == .topTrailing ? .compactPlayer : .bottomBar,
                            onOpen: { onOpen(item) },
                            onCancel: onCancel
                        )
                        .matchedGeometryEffect(id: "streamPillCapsule", in: namespace)
                        .padding(placement.edgePadding)
                        .transition(.opacity)
                    }
            }
        }
        .animation(MovieBoxMotion.streamPillAppear, value: isVisible)
        .animation(MovieBoxMotion.streamPill, value: placement)
    }

    private func pillStatusPhase(tick: PersistentPlaybackUITick) -> String {
        if !tick.rowPhase.isEmpty { return tick.rowPhase }
        switch playback.phase {
        case .preparing: return "Starting stream…"
        case .openingPlayer: return "Opening player…"
        case .failed(let message): return message
        case .buffering(_, let line): return line.components(separatedBy: " · ").first ?? line
        case .idle: return ""
        }
    }

    private var isPersistentFailed: Bool {
        if case .failed = playback.phase { return true }
        return false
    }
}

private struct RootTabBarChrome: View {
    var body: some View {
        VStack(spacing: 0) {
            PillTabBar()
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .top)
    }
}
