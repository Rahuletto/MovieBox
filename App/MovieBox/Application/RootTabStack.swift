import CoreMetadata
import SwiftUI

struct RootTabStack: View {
    @Environment(AppRouter.self) private var router

    private var tabsVisible: Bool {
        !router.isShowingDetail
    }

    var body: some View {
        ZStack {
            HomeView()
                .rootTabVisible(router.activeTab == .home && tabsVisible)

            CatalogView(kind: .movie)
                .rootTabVisible(router.activeTab == .movies && tabsVisible)

            CatalogView(kind: .tv)
                .rootTabVisible(router.activeTab == .tvShows && tabsVisible)

            LibraryView()
                .rootTabVisible(router.activeTab == .library && tabsVisible)

            DownloadsView()
                .rootTabVisible(router.activeTab == .downloads && tabsVisible)

            SearchView()
                .rootTabVisible(router.activeTab == .search && tabsVisible)
        }
    }
}
