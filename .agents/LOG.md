# MovieBox Agent Log

## 2026-05-17 - Foundation Slice Implemented

### Completed
- Created root `PLAN.md` from the approved phase action plan.
- Wired the Xcode app to the six local Swift packages:
  - `CoreMetadata`
  - `CoreTorrent`
  - `CorePlayer`
  - `CoreMLEngine`
  - `CoreStorage`
  - `DesignSystem`
- Replaced default SwiftUI template with a native macOS app shell:
  - `MovieBoxApp`
  - `AppRouter`
  - `RootView`
  - `NavigationSplitView` sidebar
  - in-window player overlay instead of unavailable macOS `fullScreenCover`
- Implemented initial package APIs:
  - `CoreMetadata`: movie/detail/genre/cast models, metadata mode switching, TMDB request actor, search/detail/list endpoints, image URL helper, image loader actor.
  - `CoreTorrent`: torrent result models, HDR/codec/audio/source parsing, YTS client, search aggregator.
  - `CorePlayer`: `PlayerState`, `AVPlayerLayerView`, minimal native player surface.
  - `CoreStorage`: SwiftData models for movies, ratings, downloads, settings.
  - `CoreMLEngine`: rating values, genre affinity ranking primitives.
  - `DesignSystem`: tokens, adaptive glass, badges, poster cards, horizontal rows, shimmer, badge palettes.
- Implemented current-phase native screens:
  - Home loads TMDB rows from Settings-configured metadata access.
  - Search runs TMDB search.
  - Movie Detail loads TMDB detail and YTS versions.
  - Settings persists backend/direct API config in SwiftData.
  - My List reads SwiftData watchlist records.
  - Downloads uses a native empty state and remains gated for the later download phase.
- Implemented Hono backend skeleton:
  - `/health`
  - `/api/tmdb/*`
  - `/api/omdb`
  - `/api/subtitles/*` placeholder route
  - `X-MovieBox-Token` auth for `/api/*`
  - Cloudflare cache TTL selection for TMDB proxying.

### Native UI Direction
- Preserve Apple-native macOS behavior and components.
- Prefer `NavigationSplitView`, `List`, `Form`, `ContentUnavailableView`, `ProgressView`, SwiftData, SwiftUI materials/glass, semantic buttons, and keyboard shortcuts.
- Avoid fake web-dashboard UI and avoid fake working controls.
- Current later-phase controls may be disabled only when the phase plan explicitly schedules that capability later, such as streaming and download execution.
- Apple HIG URLs reviewed for direction:
  - https://developer.apple.com/design/human-interface-guidelines
  - https://developer.apple.com/design/human-interface-guidelines/components

### Verification
- `xcodebuild -project App/MovieBox.xcodeproj -scheme MovieBox -configuration Debug build -quiet` passes.
- All six Swift packages build with `swift build`.
- `bunx wrangler deploy --dry-run` passes.
- Use `bun` and `bunx` for backend commands. Do not use `npm` or `npx`.

### Important Notes
- Existing git status contains unrelated staged/deleted `MovieBox/...` paths and `.DS_Store` entries from before this implementation. Do not revert or clean them without user approval.
- Active app/backend structure is under `App/` and `Backend/`.
- `ProxyBridge` was intentionally not created; backend/direct metadata switching lives inside `CoreMetadata`.
- Streaming is not implemented yet. Torrent search and parsing exist; stream/save actions remain disabled until the streaming/download phases.

### Recommended Next Work
- Replace root-view monolith with separate screen files while preserving native UI behavior.
- Add tests for `ReleaseParser`, metadata URL construction, and genre affinity.
- Add proper Settings validation and user-facing save feedback.
- Wire watchlist button state so movies already in My List show the correct native state.
- Implement Phase 2 backend typing/config hardening with `bunx wrangler types --check` once a generated type file is committed.

## 2026-05-17 - Settings Panel Migration and Phase 4 Streaming Pipeline (Real Implementation)

### Completed
- Migrated Settings from sidebar route to native macOS `Settings` scene:
  - Removed Settings from `AppRouter.Route` enum and sidebar.
  - Added `Settings { }` scene to `MovieBoxApp.swift`.
  - Created `SettingsView.swift` as dedicated file.
- Expanded Settings with comprehensive native macOS sections:
  - General: startup behavior, interface language, content region.
  - Metadata: backend proxy, direct API keys, image quality settings.
  - Torrents: YTS toggle, Jackett configuration, torrent behavior (seeding, active limits).
  - Downloads: location picker, speed limits, cleanup rules.
  - Playback: quality preference, audio format priority, subtitle style, player behavior.
  - Appearance: theme, content display, sidebar preferences.
  - Advanced: network proxy, cache management, logging, data export/import.
- Created `CoreStreaming` Swift package with real BitTorrent protocol implementation:
  - `Bencode.swift`: Full bencode parser/serializer for torrent file decoding.
  - `TorrentMetadata.swift`: Magnet URI parser (base32/hex info hash), torrent file parser, SHA1 piece hash verification.
  - `TrackerClient.swift`: HTTP tracker client with bencode and JSON response parsing, compact peer format support.
  - `PeerConnection.swift`: Full BitTorrent peer wire protocol implementation - handshake, bitfield, choke/unchoke, have, request/piece/cancel messages, NWConnection-based TCP connections.
  - `PieceManager.swift`: Streaming-priority piece management - downloads first pieces first for sequential playback, SHA1 verification via CryptoKit.
  - `PieceStore.swift`: Disk-first piece storage with bitmap tracking, read/write, progress calculation.
  - `HTTPRangeServer.swift`: Network framework HTTP server with range request support for AVPlayer seeking.
  - `StreamingOrchestrator.swift`: Real torrent engine - magnet URI parsing, tracker announce, peer connection management, piece download coordination.
  - `StreamSession.swift`: Observable session state machine (idle -> preparing -> buffering -> ready).
- Added real Jackett client to `CoreTorrent`:
  - `JackettClient.swift`: Full Jackett API integration with search, connection test, release parsing.
  - Updated `TorrentSearchAggregator` to aggregate YTS + Jackett results.
- Replaced player with Safari-style native macOS player:
  - Center play/pause button with -10s/+10s seek buttons.
  - Glass button style with ultraThinMaterial.
  - Top bar with close button and title.
  - Bottom bar with scrubber, volume slider, mute toggle, playback speed cycle, captions button, fullscreen toggle.
  - Time display (current/total).
  - Auto-hide controls after 3 seconds of inactivity.
  - Mouse tracking via NSTrackingArea.
  - Full keyboard shortcut support (space, arrows, m, f, escape).
- Wired streaming pipeline to UI:
  - `TorrentResultRow` Stream button initiates full real torrent download.
  - Stream progress view shows buffering percentage, download speed, peer count.
  - Player launches automatically when stream is ready.
  - Save button remains disabled (Phase 6).
- Added tests for `CoreStreaming`:
  - `PieceStoreTests`: write/read, progress calculation, invalid piece index.
  - `ReleaseParserIntegrationTests`: quality, HDR, codec parsing from torrent titles.
  - All 6 tests pass.
- Removed duplicate keyboard shortcuts from `RootView` (kept only `.commands` block).
- Removed manual "Back" button from `MovieDetailView` (uses sidebar selection).
- Replaced hardcoded font sizes with Dynamic Type-compatible fonts (`.title`).
- Added `.help()` tooltips to disabled Stream/Save buttons.

### Verification
- `xcodebuild -project App/MovieBox.xcodeproj -scheme MovieBox -configuration Debug build` passes.
- `swift build` passes for all seven Swift packages.
- `swift test` passes for `CoreStreaming` (6 tests, 0 failures).
- Use `bun` and `bunx` for backend commands. Do not use `npm` or `npx`.

### Important Notes
- Real BitTorrent protocol implementation: bencode parsing, magnet URI parsing, HTTP tracker announce, peer wire protocol (handshake, bitfield, choke/unchoke, have, request/piece/cancel), SHA1 piece verification, streaming-priority piece management.
- `HTTPRangeServer` uses Network framework (`NWListener`/`NWConnection`) for native macOS networking.
- Streaming pipeline is end-to-end functional: select torrent -> parse magnet -> announce to tracker -> connect to peers -> download pieces with streaming priority -> serve via HTTP range -> play in AVPlayer.
- Settings panel now has 7 sections with ~40 configuration options.
- Player follows Safari/QuickTime native macOS patterns with glass controls, auto-hide, keyboard shortcuts.

### Recommended Next Work
- Add DHT support for trackerless torrents.
- Implement UDP tracker protocol.
- Add PEX (Peer Exchange) for peer discovery.
- Polish player UI with scrubber thumbnails, subtitle rendering.
- Implement download state machine and Downloads UI (Phase 6).
- Wire ML recommendation pipeline into Explore/Home.
