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
        case personDetail(Int)
    }

    struct NavigationSnapshot: Equatable {
        var selectedRoute: Route
        var detailKind: MediaKind
        var activeTab: Route
        var personReturnRoute: Route?
        var detailReturnRoute: Route?
    }

    /// Route to restore when leaving person detail (usually `.movieDetail`).
    var personReturnRoute: Route?
    /// Route to restore when leaving title detail opened from person (usually `.personDetail`).
    var detailReturnRoute: Route?

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

    private var history: [NavigationSnapshot] = []
    private var historyIndex = 0

    init() {
        let initial = makeSnapshot()
        history = [initial]
        historyIndex = 0
    }

    var canNavigateBack: Bool { historyIndex > 0 }

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
            recordNavigation()
        }
    }

    func showDetail(id: Int, kind: MediaKind = .movie) {
        withAnimation(MovieBoxMotion.navigation) {
            if case .personDetail = selectedRoute {
                detailReturnRoute = selectedRoute
            } else {
                detailReturnRoute = nil
            }
            detailKind = kind
            selectedRoute = .movieDetail(id)
            recordNavigation()
        }
    }

    func showPerson(id: Int, returningTo: Route) {
        withAnimation(MovieBoxMotion.navigation) {
            personReturnRoute = returningTo
            selectedRoute = .personDetail(id)
            recordNavigation()
        }
    }

    func navigateBack() {
        guard canNavigateBack else { return }
        withAnimation(MovieBoxMotion.navigation) {
            historyIndex -= 1
            apply(history[historyIndex])
        }
    }

    func backFromDetail() {
        navigateBack()
    }

    func backFromPerson() {
        navigateBack()
    }

    var isShowingDetail: Bool {
        switch selectedRoute {
        case .movieDetail, .personDetail: true
        default: false
        }
    }

    // MARK: - History

    private func makeSnapshot() -> NavigationSnapshot {
        NavigationSnapshot(
            selectedRoute: selectedRoute,
            detailKind: detailKind,
            activeTab: activeTab,
            personReturnRoute: personReturnRoute,
            detailReturnRoute: detailReturnRoute
        )
    }

    private func apply(_ snapshot: NavigationSnapshot) {
        detailKind = snapshot.detailKind
        personReturnRoute = snapshot.personReturnRoute
        detailReturnRoute = snapshot.detailReturnRoute
        activeTab = snapshot.activeTab
        selectedRoute = snapshot.selectedRoute
    }

    private func recordNavigation() {
        let snap = makeSnapshot()
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        if history.last != snap {
            history.append(snap)
        }
        historyIndex = history.count - 1
    }
}

extension AppRouter.Route {
    var title: String {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .tvShows: "Shows"
        case .library: "Library"
        case .search: "Search"
        case .downloads: "Downloads"
        case .movieDetail: "Movie Detail"
        case .personDetail: "Person"
        }
    }

    var isTopLevelTab: Bool {
        switch self {
        case .home, .movies, .tvShows, .library, .downloads, .search: true
        default: false
        }
    }
}
