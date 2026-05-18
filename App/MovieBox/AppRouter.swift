import CoreMetadata
import Foundation
import SwiftUI

@MainActor
@Observable
final class AppRouter {
    enum Route: Hashable {
        case home
        case movies
        case tvShows
        case library
        case search
        case downloads
        case movieDetail(Int)
        // case demoDetail(String) // Demos disabled
    }

    var selectedRoute: Route = .home {
        didSet {
            if selectedRoute.isTopLevelTab {
                activeTab = selectedRoute
            }
        }
    }
    var activeTab: Route = .home
    var detailKind: MediaKind = .movie
    var searchQuery = ""
    var selectedGenre: GenreCard? = nil
    /// Magnet URI or raw info-hash pasted/opened from outside the app; consumed by Downloads.
    var pendingMagnetImport: String?

    func importMagnet(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingMagnetImport = trimmed
        show(.downloads)
    }

    func consumePendingMagnetImport() -> String? {
        defer { pendingMagnetImport = nil }
        return pendingMagnetImport
    }

    func show(_ route: Route) {
        let animation: Animation = switch route {
        case .home, .movies, .tvShows, .library, .downloads:
            MovieBoxMotion.tabHighlight
        case .search:
            MovieBoxMotion.chrome
        default:
            MovieBoxMotion.navigation
        }
        withAnimation(animation) {
            if route != .search {
                selectedGenre = nil
            }
            selectedRoute = route
        }
    }

    func showDetail(id: Int, kind: MediaKind = .movie) {
        withAnimation(MovieBoxMotion.navigation) {
            detailKind = kind
            selectedRoute = .movieDetail(id)
        }
    }

    // func showDemoDetail(id: String) {
    //     withAnimation(MovieBoxMotion.navigation) {
    //         selectedRoute = .demoDetail(id)
    //     }
    // }

    func backFromDetail() {
        withAnimation(MovieBoxMotion.navigation) {
            selectedRoute = activeTab
        }
    }

    var isShowingDetail: Bool {
        switch selectedRoute {
        case .movieDetail: true
        // case .demoDetail: true
        default: false
        }
    }
}

extension AppRouter.Route {
    var title: String {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .tvShows: "TV Shows"
        case .library: "Library"
        case .search: "Search"
        case .downloads: "Downloads"
        case .movieDetail: "Movie Detail"
        // case .demoDetail: "Demo"
        }
    }

    var isTopLevelTab: Bool {
        switch self {
        case .home, .movies, .tvShows, .library, .downloads, .search: true
        default: false
        }
    }
}
