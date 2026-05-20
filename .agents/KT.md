# MovieBox Knowledge Transfer (Detailed)

Welcome to MovieBox! This document serves as the primary developer onboarding resource. It details the setup, architectural subsystems, data flows, and runtime environments of the project.

---

## 1. Setup & Environment Configurations

The MovieBox workspace is composed of:
1. **Swift App**: Built using Swift 6, SwiftUI, SwiftData, and AVFoundation.
2. **Hono Proxy**: A TypeScript gateway running on Cloudflare Workers.

### Backend Setup
To run the Hono backend locally, you must use **Bun** (Node/NPM is strictly discouraged in this environment).

#### 1. Configuration (`wrangler.toml`)
Ensure the environment bindings are mapped in `Backend/wrangler.toml`:
- `compatibility_date` = "2025-01-01"
- `vars.APP_ENV` = "development"
- `kv_namespaces` binding `MOVIEBOX_CACHE` is configured.

#### 2. Local Environment Variables
Create a `.dev.vars` file in the `Backend/` directory:
```bash
TMDB_TOKEN="your_tmdb_bearer_token"
OMDB_API_KEY="your_omdb_key"
FANART_API_KEY="your_fanart_key"
APP_SECRET="your_shared_bearer_secret"
```

#### 3. Execution Commands
```bash
# Run the local wrangler development server (defaults to http://localhost:8787)
bun run dev

# Run Vitest unit/integration tests
bun run test

# Run Oxlint / Oxfmt to lint and format code
bun run lint
bun run format
```

---

## 2. Deep-Dive: SwiftUI App Subsystems

### 2a. Bootstrap & Service Registry (`MovieBoxCore`)
On launch, `MovieBoxApp.swift` initializes `AppBootstrap.swift`. This sequence:
1. Checks network connectivity via `BackendReachability.swift` to determine if it should query the Cloudflare Workers proxy or fall back to direct TMDB/OMDb requests.
2. Registers core services under `AppServices.shared` (such as `LogStore`, `CatalogLoader`, and `TorrentPlaybackCoordinator`).
3. Checks for updates using Sparkle.

### 2b. Logging Infrastructure (`LogStore`)
Logging is centralized via `LogStore.swift` inside `MovieBoxCore`.
- Logs are held in a circular in-memory ring buffer (up to 1,000 entries) for live rendering in the developer HUD.
- Logs are asynchronously flushed using a low-priority serial dispatch queue to the local file:
  `~/Library/Logs/MovieBox/moviebox.log`
- Logging levels: `.verbose`, `.debug`, `.info`, `.warning`, `.error`.

### 2c. TV Series / Episode Data Flow
To support TV Shows natively:
1. Navigation is driven by `MediaKind` ("movie" or "tv") stored in the route and `MovieRecord`.
2. When viewing a TV show detail page:
   - `MovieDetailLoader.swift` fetches the unified title bundle containing details and TVDB IDs.
   - `MovieDetailCache.swift` retrieves and caches season lists and episode details.
3. Episode Curation:
   - When an episode is selected, `TorrentEpisodeFilter.swift` and `TorrentMovieRelevanceFilter.swift` fetch all torrent results matching the show name and filter them specifically for patterns like `SxxExx` or `Sxx` or `x.xx`.
   - Results are sorted by seeder count and verified codec compatibility.

### 2d. Playback & Stream Coordination (`TorrentPlaybackCoordinator`)
Syncs the SwiftUI layout with the active video player.
1. When the user clicks "Play":
   - `TorrentPlaybackService.swift` receives the magnet URI, initializes the `StreamSession` inside `CoreStreaming`, and spins up the local HTTP Range Server.
   - It monitors `StreamSession.state` (transitioning from `.buffering` to `.ready`).
2. When `.ready` is reached:
   - The coordinator receives a local stream URL (e.g. `http://127.0.0.1:8080/stream`).
   - It instantiates the `AVPlayer` and presents the custom player interface overlay.
3. Active playback:
   - Tracks periodic times, persisting playback progress every 5 seconds into `MovieRecord` using SwiftData.
4. Clean teardown:
   - Dismissing the player triggers `stop()` on the coordinator, which terminates the `StreamSession`, stops the HTTP Range Server, and schedules removal of the temporary streaming directory `tmp/moviebox-stream/`.

---

## 3. CoreStreaming BitTorrent Protocol Architecture

The torrent client is pure Swift and does not rely on external C-libraries (like libtorrent).

```
[Peer Wire Loop] <---> [PieceManager] <---> [PieceStore] <---> [HTTPRangeServer]
                             │
                      [Piece Bitmap]
```

### 1. Peer Wire Protocol Handshake
Establishment of TCP connections with peers:
- Sends standard BitTorrent Handshake: `19 + "BitTorrent protocol" + reserved_bytes + info_hash + peer_id`.
- Exchanges extension bits (BEP 10) to support metadata transfer (BEP 9) if the torrent file bytes are not already cached.
- Once handshaked, peers send `bitfield` and `have` messages to announce pieces.

### 2. Tracker Announce (HTTP and UDP)
Announces are executed in parallel:
- **UDP Trackers**: Handled via `UDPTrackerClient`. Performs connection handshake (Action = 0) to obtain a `connection_id`, then sends announce (Action = 1) containing peer details. Uses network transaction IDs to prevent spoofing and caches connection IDs for 60 seconds per host.
- **HTTP Trackers**: Handled via `HTTPTrackerClient`. Takes care not to double-percent-encode info-hashes during parameter serialization.

### 3. Piece Selection & Block Request Pipeline
- **Head & Tail Priority**: The video index (typically at the start) and metadata details (at the end) are required immediately. `PieceManager` requests piece blocks (16KB size) sequentially for the first 10 and last 5 pieces.
- **Sequential Playhead Requesting**: Once the head/tail are acquired, request blocks from the current playhead piece forward. Maintains a pipeline of 10 in-flight requests per peer to maximize bandwidth saturation.
