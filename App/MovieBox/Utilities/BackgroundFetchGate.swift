import CorePlayer
import Foundation

/// When false, tab shells should not hit the metadata backend (catalog, hero enrichment, etc.).
enum BackgroundFetchGate {
    @MainActor
    static func allowsMetadataNetworking(
        router: AppRouter,
        playerState: PlayerState,
        tab: AppRouter.Route
    ) -> Bool {
        guard router.activeTab == tab, !router.isShowingDetail else { return false }
        if playerState.isPresented, !playerState.isPlaybackChromeHidden {
            return false
        }
        return true
    }
}
