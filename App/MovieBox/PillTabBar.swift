import DesignSystem
import SwiftUI

struct PillTabBar: View {
    @Environment(AppRouter.self) private var router

    private struct TabItem: Identifiable, Hashable {
        let id: AppRouter.Route
        let title: String
        let systemImage: String
    }

    private let tabs: [TabItem] = [
        TabItem(id: .home, title: "Home", systemImage: "house.fill"),
        TabItem(id: .tvShows, title: "TV Shows", systemImage: "tv"),
        TabItem(id: .movies, title: "Movies", systemImage: "film"),
        TabItem(id: .library, title: "Library", systemImage: "books.vertical.fill")
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                tabButton(tab)
                if index < tabs.count - 1 {
                    separator
                }
            }

            separator

            searchButton
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .adaptiveGlass(cornerRadius: 32)
        .clipShape(Capsule(style: .continuous))
        .compositingGroup()
        .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 4)
        .zIndex(10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Primary navigation")
    }

    private func tabButton(_ tab: TabItem) -> some View {
        let isSelected = currentTopLevelRoute == tab.id
        return Button {
            router.show(tab.id)
        } label: {
            Label(tab.title, systemImage: tab.systemImage)
                .labelStyle(.titleOnly)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(.primary.opacity(0.14))
                            .overlay {
                                Capsule(style: .continuous)
                                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                            }
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.25), value: isSelected)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }

    private var searchButton: some View {
        let isSelected = router.selectedRoute == .search
        return Button {
            router.show(.search)
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(width: 36, height: 32)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(.primary.opacity(0.14))
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }

    private var separator: some View {
        Capsule()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 18)
    }

    /// When the user is on a non-tab route (e.g. movieDetail), no tab is highlighted.
    private var currentTopLevelRoute: AppRouter.Route? {
        router.selectedRoute.isTopLevelTab ? router.selectedRoute : nil
    }
}
