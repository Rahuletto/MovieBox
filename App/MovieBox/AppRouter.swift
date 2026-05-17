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

    func show(_ route: Route) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.74)) {
            if route != .search {
                selectedGenre = nil
            }
            selectedRoute = route
        }
    }

    func showDetail(id: Int, kind: MediaKind = .movie) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.74)) {
            detailKind = kind
            selectedRoute = .movieDetail(id)
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
        }
    }

    var isTopLevelTab: Bool {
        switch self {
        case .home, .movies, .tvShows, .library, .downloads, .search: true
        default: false
        }
    }
}
