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

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

            RootContentView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .top)
                .opacity(playerState.isPresented ? 0 : 1)
                .allowsHitTesting(!playerState.isPresented)
                .animation(MovieBoxMotion.player, value: playerState.isPresented)
                .animation(MovieBoxMotion.navigation, value: router.selectedRoute)

            RootTabBarChrome()
                .opacity(playerState.isPresented ? 0 : 1)
                .allowsHitTesting(!playerState.isPresented)
                .animation(MovieBoxMotion.player, value: playerState.isPresented)
                .zIndex(5)

            Group {
                if playerState.isPresented {
                    PlayerView(state: playerState) {
                        PlaybackSourcesSidebar(
                            playerState: playerState,
                            torrents: appServices.playbackCoordinator.torrents
                        )
                    } streamStatsAccessory: {
                        if let session = appServices.activeSession {
                            TorrentStreamStatsAccessory(session: session)
                        }
                    }
                    .ignoresSafeArea()
                    .opacity(playerState.isPlayerRevealed ? 1 : 0)
                    .animation(MovieBoxMotion.player, value: playerState.isPlayerRevealed)
                    .transition(.opacity)
                }
            }
            .animation(MovieBoxMotion.player, value: playerState.isPresented)
            .zIndex(10)

            AppSettingsPlaybackSync()
                .allowsHitTesting(false)
        }
        .ignoresSafeArea(edges: .top)
        .background(
            WindowConfigurator(trafficLightInset: CGPoint(x: 24, y: 20), isPlayerPresented: playerState.isPresented)
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
                downloadManager: appServices.downloadManager,
                didAttachPersistence: &didAttachPersistence
            )
            #if DEBUG
            DevelopmentSettings.applyIfNeeded(modelContext: modelContext)
            let refreshed = (try? modelContext.fetch(FetchDescriptor<AppSettings>()))?.first
            TorrentBackendSync.apply(from: refreshed)
            #endif
        }
        .overlay(alignment: .top) {
            AppErrorBanner()
        }
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
