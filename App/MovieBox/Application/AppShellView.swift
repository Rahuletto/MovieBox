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
    @State private var didApplyLaunchTab = false
    @Namespace private var streamPillNamespace
    @State private var navigationTracker: TrackpadNavigationTracker?

    private var persistentPlayback: PersistentPlaybackController {
        appServices.persistentPlayback
    }

    /// Full-screen player blocks browsing (trailers, clips, etc.).
    private var isBrowsingObstructed: Bool {
        playerState.isPresented && !playerState.isPlaybackChromeHidden
    }

    private var streamPillPlacement: StreamPillPlacement {
        guard persistentPlayback.isActive, persistentPlayback.item != nil else { return .hidden }
        if isBrowsingObstructed {
            return .topTrailing
        }
        return .bottom
    }

    /// Window chrome is grey; player uses rounded corners — fill with black so letterboxing isn’t grey.
    private var shellBackdropColor: Color {
        playerState.isPresented ? .black : Color(nsColor: .windowBackgroundColor)
    }

    var body: some View {
        ZStack(alignment: .top) {
            shellBackdropColor.ignoresSafeArea()

            RootContentView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .top)
                .opacity(isBrowsingObstructed ? 0 : 1)
                .allowsHitTesting(!isBrowsingObstructed)
                .animation(MovieBoxMotion.player, value: isBrowsingObstructed)
                .animation(MovieBoxMotion.navigation, value: router.selectedRoute)
                .zIndex(playerState.isPresented && playerState.isPlaybackChromeHidden ? 8 : 0)

            RootTabBarChrome()
                .opacity(isBrowsingObstructed ? 0 : 1)
                .allowsHitTesting(!isBrowsingObstructed)
                .animation(MovieBoxMotion.player, value: isBrowsingObstructed)
                .zIndex(playerState.isPresented && playerState.isPlaybackChromeHidden ? 9 : 5)

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
                    .opacity(shellPlayerOpacity)
                    .allowsHitTesting(!playerState.isPlaybackChromeHidden && playerState.isPlayerRevealed)
                    .transition(.opacity)
                }
            }
            .animation(MovieBoxMotion.player, value: playerState.isPlaybackChromeHidden)
            .zIndex(playerState.isPlaybackChromeHidden ? 2 : 10)

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
            applyLaunchTabIfNeeded()
            if navigationTracker == nil {
                navigationTracker = TrackpadNavigationTracker(router: router)
            }
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
            applyLaunchTabIfNeeded()
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
        if playerState.isPlaybackChromeHidden { return 1 }
        if playerState.isPictureInPictureActive { return 1 }
        return playerState.isPlayerRevealed ? 1 : 0
    }

    /// Keep the AVPlayer layer fully opaque while PiP/detached so frames keep updating.
    private var shellPlayerOpacity: Double {
        if playerState.isPlaybackChromeHidden || playerState.isPictureInPictureActive {
            return 1
        }
        return playerChromeOpacity
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

    /// macOS window restoration can reopen the last tab (e.g. Library); always land on Home for a fresh session.
    private func applyLaunchTabIfNeeded() {
        guard !didApplyLaunchTab else { return }
        didApplyLaunchTab = true
        guard !router.isShowingDetail else { return }
        router.show(.home)
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
    @Environment(PlayerState.self) private var playerState

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
                        .padding(pillEdgePadding)
                        .transition(.opacity)
                    }
            }
        }
        .animation(MovieBoxMotion.streamPillAppear, value: isVisible)
        .animation(MovieBoxMotion.streamPill, value: placement)
        .animation(MovieBoxMotion.streamPill, value: playerState.showsControls)
    }

    private var pillEdgePadding: EdgeInsets {
        switch placement {
        case .topTrailing:
            let hudVisible = playerState.isPresented
                && !playerState.isPlaybackChromeHidden
                && playerState.showsControls
            // 24pt HUD inset + 36pt control row + 12pt gap; compact when controls hidden.
            let top: CGFloat = hudVisible ? 72 : 52
            return EdgeInsets(top: top, leading: 0, bottom: 0, trailing: 20)
        default:
            return placement.edgePadding
        }
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
