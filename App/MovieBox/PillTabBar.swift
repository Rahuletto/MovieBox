import DesignSystem
import SwiftUI

struct PillTabBar: View {
    @Environment(AppRouter.self) private var router
    @Namespace private var animationNamespace

    @State private var isMenuExpanded = false
    @FocusState private var isSearchFieldFocused: Bool

    private struct TabItem: Identifiable, Hashable {
        let id: AppRouter.Route
        let title: String
        let systemImage: String
    }

    private let tabs: [TabItem] = [
        TabItem(id: .home, title: "Home", systemImage: "house.fill"),
        TabItem(id: .tvShows, title: "TV Shows", systemImage: "tv"),
        TabItem(id: .movies, title: "Movies", systemImage: "film"),
        TabItem(id: .library, title: "Library", systemImage: "books.vertical.fill"),
        TabItem(id: .downloads, title: "Downloads", systemImage: "arrow.down.circle")
    ]

    var body: some View {
        HStack(spacing: 8) {
            if router.selectedRoute == .search {
                if let genre = router.selectedGenre {
                    HStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Button {
                                router.selectedGenre = nil
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.primary)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .adaptiveGlass(cornerRadius: 32)
                            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
                            .onTapGesture {}
                            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in }.onEnded { _ in })

                            Text(genre.name)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.leading, 96)

                        Spacer()
                    }
                    .offset(y: 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    HStack(spacing: 8) {
                        if isMenuExpanded {
                            HStack(spacing: 2) {
                                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                                    tabButton(tab)
                                    if index < tabs.count - 1 {
                                        separator
                                    }
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                            .adaptiveGlass(cornerRadius: 32)
                            .clipShape(Capsule(style: .continuous))
                            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
                            .matchedGeometryEffect(id: "menu-capsule", in: animationNamespace)
                            .onTapGesture {}
                            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in }.onEnded { _ in })

                            Button {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                    isMenuExpanded = false
                                }
                            } label: {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.primary)
                                    .frame(width: 32, height: 32)
                                    .background(Circle().fill(.primary.opacity(0.22)))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .adaptiveGlass(cornerRadius: 32)
                            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
                            .matchedGeometryEffect(id: "search-capsule", in: animationNamespace)
                            .onTapGesture {}
                            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in }.onEnded { _ in })
                        } else {
                            Button {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                    isMenuExpanded = true
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.primary)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .adaptiveGlass(cornerRadius: 32)
                            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
                            .matchedGeometryEffect(id: "menu-capsule", in: animationNamespace)
                            .onTapGesture {}
                            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in }.onEnded { _ in })

                            HStack(spacing: 10) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)

                                TextField("Search movies and shows", text: Binding(
                                    get: { router.searchQuery },
                                    set: { router.searchQuery = $0 }
                                ))
                                .textFieldStyle(.plain)
                                .font(.system(size: 14, weight: .medium))
                                .focused($isSearchFieldFocused)
                                .fixedSize(horizontal: true, vertical: false)

                                if !router.searchQuery.isEmpty {
                                    Button {
                                        router.searchQuery = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .opacity(isMenuExpanded ? 0 : 1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(width: 380)
                            .adaptiveGlass(cornerRadius: 32)
                            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
                            .matchedGeometryEffect(id: "search-capsule", in: animationNamespace)
                            .onTapGesture {}
                            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in }.onEnded { _ in })
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                            tabButton(tab)
                            if index < tabs.count - 1 {
                                separator
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                    .adaptiveGlass(cornerRadius: 32)
                    .clipShape(Capsule(style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
                    .matchedGeometryEffect(id: "menu-capsule", in: animationNamespace)
                    .onTapGesture {}
                    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in }.onEnded { _ in })

                    searchButton
                        .frame(width: 32, height: 32)
                        .adaptiveGlass(cornerRadius: 32)
                        .clipShape(Capsule(style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
                        .matchedGeometryEffect(id: "search-capsule", in: animationNamespace)
                        .onTapGesture {}
                        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in }.onEnded { _ in })
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity)
        .compositingGroup()
        .zIndex(10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Primary navigation")
        .onChange(of: router.selectedRoute) { _, newValue in
            if newValue == .search {
                isMenuExpanded = false
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    isSearchFieldFocused = true
                }
            } else {
                isSearchFieldFocused = false
            }
        }
        .onChange(of: isMenuExpanded) { _, newValue in
            if !newValue && router.selectedRoute == .search {
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    isSearchFieldFocused = true
                }
            } else {
                isSearchFieldFocused = false
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.74), value: router.selectedRoute)
        .animation(.spring(response: 0.38, dampingFraction: 0.74), value: router.selectedGenre)
        .animation(.spring(response: 0.38, dampingFraction: 0.74), value: isMenuExpanded)
    }

    private func tabButton(_ tab: TabItem) -> some View {
        let isSelected = currentTopLevelRoute == tab.id
        return Button {
            router.show(tab.id)
        } label: {
            Label(tab.title, systemImage: tab.systemImage)
                .labelStyle(.titleOnly)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .fixedSize(horizontal: true, vertical: false)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(.primary.opacity(0.22))
                            .matchedGeometryEffect(id: "active-tab-highlight", in: animationNamespace)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.32, dampingFraction: 0.74), value: isSelected)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }

    private var searchButton: some View {
        let isSelected = router.selectedRoute == .search
        return Button {
            router.show(.search)
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if isSelected {
                        Circle()
                            .fill(.primary.opacity(0.22))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }

    private var separator: some View {
        Capsule()
            .fill(Color.primary.opacity(0.10))
            .frame(width: 1, height: 14)
    }

    private var currentTopLevelRoute: AppRouter.Route? {
        router.selectedRoute.isTopLevelTab ? router.selectedRoute : nil
    }
}
