# MovieBox Knowledge Transfer

## Current State

MovieBox is a native macOS SwiftUI app with a Hono backend on Cloudflare Workers. All six Swift packages are wired, streaming pipeline is end-to-end functional with real BitTorrent protocol (HTTP+UDP trackers, DHT), and all critical UI features are implemented.

Done:
- Xcode app wired to seven local Swift packages:
  - `CoreMetadata` - TMDB/OMDb/backend clients, image loading, subtitle client
  - `CoreTorrent` - YTS/Jackett search, release parsing, aggregation
  - `CorePlayer` - Safari-style native player with glass controls, keyboard shortcuts, subtitle support
  - `CoreMLEngine` - genre affinity ranking primitives
  - `CoreStorage` - SwiftData models for movies, ratings, downloads, playback progress, settings
  - `DesignSystem` - tokens, adaptive glass, poster rows, badges, cards, shimmer
  - `CoreStreaming` - real BitTorrent protocol (bencode, magnet URI, HTTP+UDP trackers, DHT, peer wire protocol, piece management, HTTP range server, download manager)
- Root app shell in SwiftUI/macOS:
  - `MovieBoxApp`, `AppRouter`, `RootView`
  - Native macOS patterns: `NavigationSplitView`, `List`, `Form`, `ContentUnavailableView`, `ProgressView`, SwiftData, toolbar search, native Settings scene
- Home view: hero section, category rows, search (`.searchable`), recommended for you, continue watching row
- Explore view: ML-ranked discovery using `GenreAffinityEngine`, trending & top rated sections
- Movie Detail view: header with 5-star rating, cast scroll, torrent versions, subtitle search/download/select, similar movies
- Downloads view: active download tasks with pause/resume/cancel, completed downloads with "Show in Finder"
- My List view: grid layout with posters, watch progress badges, context menu to remove
- Settings: native macOS Settings panel with 7 sections, 40+ options, proper save/persist mechanism with Cmd+S
- `CoreStreaming` has real BitTorrent protocol implementation:
  - `Bencode`: Full bencode parser/serializer
  - `TorrentMetadata`: Magnet URI parser (base32/hex), torrent file parser
  - `TrackerClient`: HTTP tracker client with bencode/JSON parsing
  - `UDPTrackerClient`: UDP tracker protocol (connect + announce)
  - `KademliaDHT`: Kademlia DHT with bootstrap, find_node, announce_peer, routing table
  - `PeerConnection`: Full peer wire protocol (handshake, bitfield, choke/unchoke, have, request/piece/cancel)
  - `PieceManager`: Streaming-priority piece management with SHA1 verification
  - `PieceStore`: Disk-first piece storage with bitmap tracking, contiguous pieces from start
  - `HTTPRangeServer`: Network framework HTTP server with range request support
  - `StreamingOrchestrator`: Torrent engine with tracker announce (HTTP+UDP), DHT fallback, peer management
  - `StreamSession`: Observable session state machine, ready at 10 contiguous pieces (not 100%)
  - `DownloadManager`: Download task management with pause/resume/cancel, progress tracking
- Streaming pipeline is end-to-end functional:
  - Stream button initiates real torrent download via BitTorrent protocol
  - HTTP + UDP tracker announce, DHT fallback for trackerless torrents
  - Peer wire protocol TCP connections via Network framework
  - Streaming-priority piece download (first pieces first)
  - SHA1 piece verification via CryptoKit
  - HTTP range server serves pieces for AVPlayer seeking
  - Player launches automatically when stream is ready (buffer threshold: 10 pieces)
  - Watch history tracked: playback position and fraction saved every 5 seconds
- Backend exists in Hono with:
  - `/health` - health check
  - `/api/tmdb/*` - TMDB proxy with KV caching, Cloudflare edge caching, per-path TTL
  - `/api/omdb` - OMDb proxy with KV caching
  - `/api/subtitles/search` - subf2m HTML scraping (search + detail parsing)
  - `/api/subtitles/download` - subtitle download, ZIP extraction to SRT
  - Auth via `X-MovieBox-Token`
  - Rate limiting via KV (configurable window/max)
  - CORS with configurable origins
  - Security headers, request logging with timing
- Player features:
  - Full glass HUD with auto-hide controls (3s timeout)
  - Keyboard shortcuts: space, arrows, m, f, escape
  - Subtitle toggle button (enabled, loads SRT via AVPlayer)
  - Playback rate cycling (0.5x-2.0x)
  - Volume slider, mute toggle
  - Time display, scrubber
  - Watch position callback for history tracking
- Docs:
  - `.agents/LOG.md`
  - `.agents/DESIGN.md`
  - `PLAN.md`
  - `.agents/KT.md` (this file)

## Native UI Decisions Already Locked

- Do not use a permanent black background for browsing/settings/detail screens.
- Use system backgrounds and materials.
- Use `NavigationSplitView` for app navigation.
- Keep the player black because that is the one place it is correct.
- Settings is a native macOS Settings panel, not a sidebar route.
- Search lives in Home via toolbar `.searchable`, not as a separate tab/page.
- Explore is the separate discovery tab.
- Use native macOS controls and semantic colors, not dashboard-style custom chrome.
- Use `bun` and `bunx` only for backend commands.
- Player follows Safari/QuickTime native macOS patterns.

## What Is Still Left

### Phase 5 - Player Polish
- Scrubber thumbnails
- HDR display awareness
- Audio track selection
- Chapter markers
- Picture-in-picture support
- Now Playing integration (MediaRemote/MPNowPlayingInfoCenter)
- Trailer playback (YouTube/Vimeo)

### Phase 6 - Downloads And ML
- Download state machine persistence across app restarts
- Local file playback for completed downloads
- Speed limit enforcement
- Seeding after download
- Real ML ranking pipeline with on-device model training
- Hybrid recommendation blending

### Phase 7 - Shipping
- Sparkle 2 integration
- Release workflow, notarization
- Appcast signing
- GitHub Releases packaging
- Setup documentation

### Torrent Protocol Enhancements
- PEX (Peer Exchange) for peer discovery
- LTEP (Local Tracker Extension Protocol)
- Fast extension support
- Encryption protocol (PE/MSE)

### UI Polish
- Split `RootView.swift` into separate screen files
- Skeleton loading states for movie detail
- Error boundaries for individual rows
- Grid/list view toggle
- Movie count badges on categories
- Pull-to-refresh on views

### Backend
- `/api/ratings` endpoint
- `/api/recommendations` endpoint
- `/api/watchlist` endpoint
- API versioning
- Input validation/sanitization

### Settings
- Clear cache implementation
- Log export
- Watchlist import/export
- Jackett connection test
- Settings validation
- Open at login implementation

## Current Risks / Caveats

- `HTTPRangeServer` uses Network framework; may need tuning for high-throughput streaming.
- Peer connections use TCP only; UDP tracker and DHT are implemented but may need real-world testing.
- Subtitle loading: SRT files are downloaded fully but parsed into cues; display is synced to playback time.
- Download engine uses same `TorrentEngine` as streaming; may need separate port allocation to avoid conflicts.
- Settings panel has some disabled controls for future phases (cache clear, log export, etc.).

## Files To Read First

- [PLAN.md](/Users/marban/Documents/Coding/moviebox/PLAN.md)
- [.agents/LOG.md](/Users/marban/Documents/Coding/moviebox/.agents/LOG.md)
- [.agents/DESIGN.md](/Users/marban/Documents/Coding/moviebox/.agents/DESIGN.md)
- [App/MovieBox/MovieBoxApp.swift](/Users/marban/Documents/Coding/moviebox/App/MovieBox/MovieBoxApp.swift)
- [App/MovieBox/AppRouter.swift](/Users/marban/Documents/Coding/moviebox/App/MovieBox/AppRouter.swift)
- [App/MovieBox/RootView.swift](/Users/marban/Documents/Coding/moviebox/App/MovieBox/RootView.swift)
- [App/MovieBox/SettingsView.swift](/Users/marban/Documents/Coding/moviebox/App/MovieBox/SettingsView.swift)
- [App/CoreStreaming/Sources/CoreStreaming/StreamingOrchestrator.swift](/Users/marban/Documents/Coding/moviebox/App/CoreStreaming/Sources/CoreStreaming/StreamingOrchestrator.swift)
- [App/CoreStreaming/Sources/CoreStreaming/DownloadManager.swift](/Users/marban/Documents/Coding/moviebox/App/CoreStreaming/Sources/CoreStreaming/DownloadManager.swift)
- [App/CorePlayer/Sources/CorePlayer/CorePlayer.swift](/Users/marban/Documents/Coding/moviebox/App/CorePlayer/Sources/CorePlayer/CorePlayer.swift)
- [Backend/src/index.ts](/Users/marban/Documents/Coding/moviebox/Backend/src/index.ts)

## Next Work Order

1. Add PEX (Peer Exchange) for peer discovery.
2. Implement scrubber thumbnails and HDR display awareness.
3. Add audio track selection and chapter markers.
4. Implement PiP and Now Playing integration.
5. Split `RootView.swift` into separate screen files.
6. Add skeleton loading states and error boundaries.
7. Implement download persistence across app restarts.
8. Wire ML recommendation pipeline with on-device training.
9. Add backend endpoints for ratings, recommendations, watchlist.
10. Finalize Settings UX with validation and save feedback.
11. Begin Phase 7 shipping work (Sparkle, notarization, releases).

## Command Rules

- Use `bun` / `bunx` for backend work.
- Use `xcodebuild` and `swift build` / `swift test` for Swift verification.
- Do not use `npm` or `npx`.
- Do not revert unrelated staged/deleted `MovieBox/...` paths in the worktree.
