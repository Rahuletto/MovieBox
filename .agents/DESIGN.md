# MovieBox Design Guide

This file is the UI contract for agents working on MovieBox. The app must feel like a native macOS app first, not a custom web dashboard wrapped in SwiftUI.

## Sources To Follow
- Apple Human Interface Guidelines: https://developer.apple.com/design/human-interface-guidelines
- Apple HIG Components: https://developer.apple.com/design/human-interface-guidelines/components
- Apple HIG Toolbars: https://developer.apple.com/design/human-interface-guidelines/toolbars
- Apple HIG Sidebars: https://developer.apple.com/design/human-interface-guidelines/sidebars
- Apple SwiftUI Documentation: https://developer.apple.com/documentation/swiftui
- SwiftUI `NavigationSplitView`: https://developer.apple.com/documentation/swiftui/navigationsplitview
- SwiftUI `ContentUnavailableView`: https://developer.apple.com/documentation/swiftui/contentunavailableview
- SwiftUI Search: https://developer.apple.com/documentation/SwiftUI/Adding-a-search-interface-to-your-app
- Explore SwiftUI visual component library: https://exploreswiftui.com/

## Non-Negotiable Native Direction
- Use system backgrounds: `Color(nsColor: .windowBackgroundColor)`, `.controlBackgroundColor`, `.textBackgroundColor`, `.underPageBackgroundColor` where appropriate.
- Do not use a hardcoded black app canvas for browsing/settings/detail screens.
- Respect Light Mode and Dark Mode automatically. Avoid forcing a permanent dark theme.
- Prefer platform components over custom controls: `NavigationSplitView`, `List`, `Table`, `Form`, `Settings`, `ToolbarItem`, `ContentUnavailableView`, `ProgressView`, `Menu`, `Picker`, `Toggle`, `Stepper`, `Slider`, `SearchField` via `.searchable`.
- Use SF Symbols in labels and toolbar items. Do not invent icon systems.
- Use standard macOS typography through `.title`, `.title2`, `.headline`, `.body`, `.callout`, `.caption`, or system rounded only when the screen benefits from media personality.
- Use primary/secondary/tertiary semantic text colors. Avoid white text unless the content is on video, artwork, or a genuinely dark material surface.
- Use materials sparingly: `.regularMaterial`, `.thinMaterial`, `.bar`, and Liquid Glass where available. Material is not a replacement for layout.
- Use native empty/error states with `ContentUnavailableView`, not blank panels or fake placeholder cards.
- Toolbar actions must be real and relevant to the current view. Do not add non-working toolbar buttons.
- Disable later-phase actions only when the phase plan explicitly says the capability is not implemented yet. Label or tooltip them clearly if needed.

## App Structure Pattern
MovieBox should follow a common macOS media/library structure:
- Sidebar: global sections such as Home, Search, Downloads, My List, Settings.
- Detail column: current content surface.
- Toolbar: current title, search field where appropriate, and a small number of high-value actions.
- Settings: native `Settings` scene or grouped `Form`, not a custom dashboard.
- Lists/tables: use native `List`/`Table` for structured records like downloads, watchlist, search results, and torrent versions when density matters.

## Screen Rules

### Home
- Use system window background.
- Use a restrained featured item card, not a black hero banner.
- Movie rows can use poster cards, but cards must sit naturally on the system background.
- Loading: use `ProgressView`.
- Empty/missing API config: use `ContentUnavailableView` with a clear Settings action.
- Search should preferably be available from the toolbar or a native search field, not a custom oversized search box.

### Search
- Prefer `.searchable(text:placement:prompt:)` on a `NavigationSplitView` or content view. Apple docs note that on macOS this places search in the toolbar when possible.
- Results should be a `List` or `Table`.
- Empty results should use `ContentUnavailableView.search` or a custom `ContentUnavailableView`.
- Do not make search look like a web landing-page input.

Sample:
```swift
NavigationSplitView {
    List(selection: $selection) {
        ForEach(results) { movie in
            NavigationLink(movie.title, value: movie.id)
        }
    }
    .searchable(text: $query, placement: .toolbar, prompt: "Search Movies")
} detail: {
    MovieDetailView(movieID: selection)
}
```

### Movie Detail
- Use a native detail layout: poster/media well, title, metadata chips, synopsis, cast, and versions.
- Avoid full-window black backgrounds unless a video player is active.
- Torrent versions should be a native list/table-like section with badges as secondary visual information.
- Primary actions must work. If streaming is not implemented, the Stream button must be disabled and not styled as the main action.

Sample:
```swift
VStack(alignment: .leading, spacing: 20) {
    HStack(alignment: .top, spacing: 20) {
        PosterView(url: posterURL)
        VStack(alignment: .leading, spacing: 8) {
            Text(movie.title).font(.title)
            Text(movie.overview).foregroundStyle(.secondary)
            HStack { RatingBadge(...); RuntimeBadge(...) }
        }
    }

    Section("Available Versions") {
        List(torrents) { TorrentVersionRow(result: $0) }
    }
}
```

### Player
- The player is the one place where black is correct because video playback uses a black stage.
- Controls should feel like QuickTime/TV.app: minimal, transient, overlayed, keyboard-driven.
- Use `AVPlayerLayer`, not WebView.
- Use glass/material overlay only for controls; do not obscure video.
- Keep controls discoverable with native keyboard shortcuts.

### Downloads
- Use `List` or `Table`.
- Use native `ProgressView` for progress.
- Row actions should be compact: Pause/Resume, Reveal in Finder, Delete.
- Use destructive roles for destructive buttons.

### Settings
- Use native grouped `Form` or a proper macOS `Settings` scene.
- Keep secrets in secure fields.
- Use standard controls:
  - `TextField` for URLs/languages.
  - `SecureField` for API keys.
  - `Toggle` for boolean features.
  - `Picker` for quality preferences.
  - `Stepper` or numeric field for ports/speed limits.
- Avoid custom cards for basic preferences.

## Component Choices From Apple / SwiftUI / Explore SwiftUI
- Navigation: `NavigationSplitView`, `NavigationStack`, `NavigationLink`.
- Toolbar: `.toolbar`, `ToolbarItem`, `ToolbarSpacer`, title placement, search placement.
- Search: `.searchable`.
- Empty states: `ContentUnavailableView`.
- Lists: `List`, `Section`, `DisclosureGroup`, `Table` for dense desktop data.
- Forms/settings: `Form`, grouped sections, `Toggle`, `Picker`, `TextField`, `SecureField`.
- Progress: `ProgressView` with linear style for downloads and circular style for loading.
- Menus: `Menu`, context menus for secondary row actions.
- Pickers:
  - `.segmented` only for 2-5 short options.
  - `.menu` for longer choices.
  - `.radioGroup` can be appropriate in macOS settings.
- Buttons:
  - Use normal `Button` styles by default.
  - Use roles: `.destructive`, `.cancel`.
  - Use `Label` with SF Symbol where it improves clarity.
  - Avoid oversized custom pill buttons except in media/player-specific surfaces.
- Materials:
  - `.regularMaterial` for contained panels.
  - `.bar`/toolbar-managed backgrounds for toolbar areas.
  - Liquid Glass/glass effects only where platform-available and contextually appropriate.

## Visual Defaults
- Background: system window background.
- Content panels: regular material or control background with subtle stroke only if needed.
- Text: `.primary`, `.secondary`, `.tertiary`.
- Accent: use app tint for rating/action highlights, not for all surfaces.
- Spacing: follow macOS density. Avoid huge mobile-style vertical whitespace.
- Corners: moderate radii. Avoid giant web-card radii everywhere.
- Shadows: subtle, rare. Native macOS surfaces usually rely on materials, separators, and hierarchy more than big shadows.

## Things Agents Must Not Do
- Do not hardcode a full-app black background.
- Do not make Settings look like a SaaS dashboard.
- Do not use fake placeholder movie data on current-phase screens when real API configuration exists.
- Do not add visible buttons that do nothing.
- Do not use `fullScreenCover` on macOS; it is unavailable.
- Do not use web layout tropes: giant hero gradients, neon badges everywhere, marketing-page cards, custom side navs.
- Do not use `npm` or `npx`; this repo uses `bun` and `bunx`.

## Current App-Specific Decisions
- Keep the six-package architecture.
- `CoreMetadata` owns backend/direct metadata switching.
- `DesignSystem` should wrap native styling, not replace native controls.
- Streaming/download actions remain disabled until the streaming/download phases are implemented.
- The only intentionally black surface should be video playback.
