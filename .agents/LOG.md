# MovieBox Agent Log (Detailed Changelog)

This document chronicles the step-by-step progress, architecture refactorings, commit history, and design rationales during the development of MovieBox.

---

## 2026-05-17 - Core Skeleton and Initial Package Wiring (Phase 1 & 2)

### Architecture Decisions
To ensure strict modularity and build efficiency, the core subsystems were mapped out into specialized local Swift packages. This prevents compiler bottleneck issues and ensures clean separation of concerns.

### Implementation Details
- **App Shell Setup**: Created the native macOS application target. Replaced default boilerplate with a custom navigation stack driven by `AppRouter.swift` (using the modern `@Observable` state macro).
- **Modularity Wiring**: Linked 6 core local packages under `App/`:
  - **`CoreMetadata`**: Created TMDB and OMDb API mappings. Integrated a background-actor-based image loader to fetch poster files asynchronously.
  - **`CoreTorrent`**: Built the `TorrentResult` models. Added initial regex parsing in `ReleaseParser.swift` for basic quality/codec checks.
  - **`CorePlayer`**: Bound `AVPlayer` to a native `AVPlayerLayer` represented in SwiftUI.
  - **`CoreMLEngine`**: Set up basic linear affinity metrics.
  - **`CoreStorage`**: Added SwiftData schemas (`MovieRecord`, `RatingRecord`, `DownloadRecord`, `AppSettings`).
  - **`DesignSystem`**: Implemented styling guidelines for Liquid Glass cards and badging.
- **Backend Skelton**: Initiated Hono on Cloudflare Workers with transparent reverse-proxies to TMDB/OMDb (`/api/tmdb/*`, `/api/omdb`) to protect API keys.

---

## 2026-05-17 - BitTorrent Engine & Custom Video HUD Player (Phase 3 & 4)

### Architecture Decisions
BitTorrent streaming must bypass the main thread. We introduced a dedicated `CoreStreaming` package to isolate TCP peer wire sockets, DHT routines, and file handling on background workers.

### Implementation Details
- **`CoreStreaming` Implementation**:
  - Implemented `PieceStore.swift` to handle file writing.
  - Implemented `PieceManager.swift` to coordinate head/tail priority pieces.
  - Built `HTTPRangeServer.swift` utilizing SwiftNIO to serve partial bytes to `AVPlayer`.
- **Custom Player HUD**:
  - Created a custom overlay with volume sliders, track seek scrubbers, speed switchers, and keyboard mappings (Space to toggle play, arrows to skip).
  - Used `.ultraThinMaterial` for the Sequoia-targeted UI.
- **Sidecar Integration**:
  - Added support for running local Jackett instances as a sidecar process to expand torrent search indexing.

---

## 2026-05-18 - Modular Separation & View Hierarchy Refactoring

### Architecture Decisions
The monolithic `RootView.swift` grew to 1,450 lines. To restore code maintainability, views were split into feature-specific directories. In addition, the shared core loaders and detail loaders were isolated into new packages: `MovieBoxCore` and `MovieBoxDetail`.

### Implementation Details
- **UI File Organization**: Split `RootView` into sub-views located in `App/MovieBox/Views`:
  - `Home/HomeView.swift` & `Home/HeroCarousel.swift`
  - `Detail/MovieDetailView.swift` & `Detail/TorrentResultsPanel.swift`
  - `Search/SearchView.swift`
  - `Downloads/DownloadsView.swift`
  - `Settings/SettingsView.swift`
- **`MovieBoxCore` Package**:
  - Extracted bootstrap logic into `AppBootstrap.swift`.
  - Added a central service registry `AppServices.swift`.
  - Implemented `CatalogCache` inside `CatalogLoader.swift` containing a 5-minute memory cache to prevent redundant TMDB network calls when navigating tabs.
  - Created `LogStore.swift` to handle log buffering and background file writing.
- **`MovieBoxDetail` Package**:
  - Created `MovieDetailLoader.swift` for fetching title details.
  - Added season/episode lists curation inside `MovieDetailCache.swift` to support TV shows.
  - Implemented relevance metrics in `TorrentMovieRelevanceFilter.swift` to block mistitled/fake release matches.

---

## 2026-05-19 - Progressive Search Streams, Dolby Vision & Rotten Tomatoes

### Architecture Decisions
Standard HTTP request-response patterns caused long page delays during multi-tracker searches. We introduced Server-Sent Events (SSE) to stream torrent matches progressively to the client.

### Implementation Details
- **SSE Stream Endpoints**: Added `/api/torrent/search/stream` to the Hono backend. The route queries YTS and Torrentio indexers in parallel and immediately streams back results as chunked data.
- **Dolby Vision & Atmos Support**: Expanded `ReleaseParser.swift` to detect HDR types (`dolbyVisionWithHDR10`, `dolbyVisionOnly`, `hdr10Plus`, `hdr10`, `hlg`) and audio codecs (`dolbyAtmos`, `truehd`, `dtshd`, `eac3`).
- **Levenshtein Sorting**: Added edit-distance algorithms to verify search matches and sort results based on exact title proximity.
- **Rotten Tomatoes & Trailer resolver**:
  - Added scraper inside `/api/title/:kind/:id` to fetch Tomatometer critiques.
  - Resolved trailer video streams by parsing Fandango/MPX thePlatform links and fetching the master `.m3u8` variant.

---

## 2026-05-20 - BitTorrent, DHT Compliance, & HTTPRangeServer Correctness

### Architecture Decisions
Fixed several bugs in the custom BitTorrent pipeline to resolve streaming hangs and test failures.

### Implementation Details
- **Piece Assembly Writes**: Fixed block offset calculations in `PieceStore.swift`. Prevented block chunk writes from overwriting piece ranges at offset 0.
- **UDP Announce Caching**: Tracker announce loops now isolate and cache transaction/connection IDs per tracker socket address, preventing connection sharing mismatches.
- **DHT BEP 5 Standard Compliance**: Fixed bencoding structures in `DHTCodec.swift` to parse and serialize compact nodes (26 bytes) and compact peers (6 bytes) conforming to BitTorrent BEP 5.
- **HTTP Range Server Fix**: Standardized response headers in `HTTPRangeServer.swift` to serve correct range bytes (Status 206) and clamped request indices to prevent out-of-bounds errors on AVPlayer seek.
