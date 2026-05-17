import CoreMetadata
import Foundation

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
    }

    var selectedRoute: Route = .home
    var detailKind: MediaKind = .movie
    var searchQuery = ""

    func show(_ route: Route) {
        selectedRoute = route
    }

    func showDetail(id: Int, kind: MediaKind = .movie) {
        detailKind = kind
        selectedRoute = .movieDetail(id)
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
        }
    }

    var isTopLevelTab: Bool {
        switch self {
        case .home, .movies, .tvShows, .library: true
        default: false
        }
    }
}
