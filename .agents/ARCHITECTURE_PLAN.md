# MovieBox — macOS Native Architecture Plan
> Codename: MovieBox  
> Stack: Swift 6 · SwiftUI · AVFoundation · Core ML  
> Target: macOS Sequoia (15+) with Liquid Glass on macOS Tahoe (26+)  
> Distribution: GitHub Releases + Sparkle auto-updater  
> Backend: Optional Hono/TypeScript proxy on Cloudflare Workers

---

## 0. North Star: Efficiency First

The reason this is a native Swift app and not Electron is performance. Every architectural decision is weighed against this. Rules:

- **Zero JS bridges.** No WebView for anything except an optional trailer preview.
- **Actor isolation everywhere.** Swift 6 strict concurrency — no data races, no `@MainActor` bottlenecks in network/torrent code.
- **Lazy loading is the default.** Nothing outside the current viewport loads eagerly.
- **Write pieces to disk, not RAM.** Torrent streaming never buffers more than 2 pieces in memory.
- **AVFoundation for all decode.** Hardware-accelerated on Apple Silicon. No FFmpeg decode path (only FFmpeg remux for MKV→MP4 container swap, which is pure I/O — no transcode).
- **NSCache + URLCache for images.** Never duplicate an image in memory across views.
- **SwiftData for all persistence.** No SQLite wrappers, no JSON files, no UserDefaults sprawl.

---

## 1. Codebase Module Map

```
MovieBox/                            ← Xcode project root
├── App/                             ← App target — thin wiring only
│   ├── MovieBoxApp.swift            ← @main, scene setup, DI root
│   ├── AppDelegate.swift            ← Termination hooks (kill Jackett, stop torrents)
│   ├── AppRouter.swift              ← @Observable navigation state machine
│   └── Assets.xcassets
│
├── Packages/
│   ├── CoreMetadata/                ← TMDB + OMDb clients, movie models, caching
│   ├── CoreTorrent/                 ← Torrent engine, Jackett/YTS search, streaming server
│   ├── CorePlayer/                  ← AVPlayer stack, custom HUD, HDR, subtitles
│   ├── CoreML_Engine/               ← Ratings, genre affinity, MLRecommender training
│   ├── CoreStorage/                 ← SwiftData schemas, download queue, watchlist
│   ├── DesignSystem/                ← Tokens, Liquid Glass components, animations
│   └── ProxyBridge/                 ← (optional) HTTP client to talk to the Hono backend
│
├── Backend/                         ← Hono/TypeScript proxy (separate repo or monorepo)
│   ├── src/
│   │   ├── index.ts                 ← Hono app entry
│   │   ├── routes/
│   │   │   ├── tmdb.ts              ← TMDB proxy (hides API key)
│   │   │   ├── omdb.ts              ← OMDb proxy
│   │   │   ├── subtitles.ts         ← OpenSubtitles proxy
│   │   │   └── jackett.ts           ← Optional: remote Jackett relay
│   │   └── middleware/
│   │       ├── cache.ts             ← KV-backed edge cache
│   │       └── ratelimit.ts
│   ├── wrangler.toml
│   └── package.json
│
└── MovieBox.xcodeproj
```

---

## 2. Why a Hono Backend (and When to Use It)

The Swift app can call TMDB and OMDb directly — both have free tiers. But there are three reasons to put a Hono proxy on Cloudflare Workers in front:

1. **API key security.** Your TMDB and OMDb keys are never shipped inside the app binary. The proxy holds them in Cloudflare environment secrets.
2. **Edge caching.** Trending lists, genre lists, and popular movies barely change. Cache them at the edge with `Cache-Control` and Cloudflare KV — the app gets sub-50ms responses for these.
3. **Region handling.** Cloudflare Workers are globally distributed. The app always hits the nearest PoP.

For torrent search (Jackett/YTS) the proxy is optional — Jackett runs locally as a sidecar, and YTS API is public. Only add a remote Jackett relay in the backend if you want to share a remote Jackett instance across multiple Macs.

### Backend routes (Hono/TypeScript)

```typescript
// src/routes/tmdb.ts
app.get('/api/tmdb/*', async (c) => {
  const path = c.req.path.replace('/api/tmdb', '')
  const query = new URL(c.req.url).search
  const upstream = `https://api.themoviedb.org/3${path}${query}`

  // Check KV cache first (for stable endpoints like /genre/movie/list)
  const cacheKey = `tmdb:${path}${query}`
  const cached = await c.env.CACHE_KV.get(cacheKey)
  if (cached) return c.json(JSON.parse(cached))

  const res = await fetch(upstream, {
    headers: { Authorization: `Bearer ${c.env.TMDB_TOKEN}` }
  })
  const data = await res.json()

  // Cache stable endpoints for 1 hour
  if (isStableEndpoint(path)) {
    await c.env.CACHE_KV.put(cacheKey, JSON.stringify(data), { expirationTtl: 3600 })
  }

  return c.json(data)
})
```

The Swift `ProxyBridge` package wraps these endpoints. If the backend URL is not configured (empty string in Settings), `ProxyBridge` falls back to calling TMDB/OMDb directly with keys from Keychain. This makes the backend entirely optional — the app works standalone.

---

## 3. Package: `CoreMetadata`

### TMDB Endpoints

| Endpoint | Route | Cache TTL |
|---|---|---|
| `GET /trending/movie/week` | Home hero | 30 min |
| `GET /movie/popular` | Popular row | 30 min |
| `GET /movie/top_rated` | Top Rated row | 1 hr |
| `GET /movie/now_playing` | In Theatres | 15 min |
| `GET /movie/{id}` | Detail page | 6 hr |
| `GET /movie/{id}/credits` | Cast row | 6 hr |
| `GET /movie/{id}/videos` | Trailers | 6 hr |
| `GET /movie/{id}/images` | Backdrops | 6 hr |
| `GET /movie/{id}/similar` | More Like This | 1 hr |
| `GET /movie/{id}/external_ids` | Get IMDB ID | 24 hr |
| `GET /search/movie?query=` | Search | no cache |
| `GET /genre/movie/list` | Genre chips | 24 hr |

For actual IMDB ratings: use the IMDB ID from `external_ids`, then call OMDb (`http://www.omdbapi.com/?i=ttXXXX`). Run TMDB detail + OMDb in a `TaskGroup` — both resolve in parallel.

### Key types

```swift
// Sendable, Codable, Identifiable — safe to pass across actor boundaries
public struct Movie: Sendable, Codable, Identifiable {
    public let id: Int
    public let title: String
    public let overview: String
    public let posterPath: String?
    public let backdropPath: String?
    public let releaseDate: String
    public let voteAverage: Double          // TMDB score
    public let genreIds: [Int]
    public let runtime: Int?                // minutes
    public var imdbRating: String?          // "8.4" from OMDb, filled async
    public var imdbId: String?              // "tt1234567"
}
```

### Image loading

Use a custom `ImageLoader` actor backed by `URLCache` (250MB disk, 50MB memory). SwiftUI views use a `CachedAsyncImage` wrapper — never `AsyncImage` directly (it doesn't deduplicate in-flight requests). All poster fetches share a single `URLSession` instance configured with HTTP/2 and connection coalescing.

---

## 4. Package: `CoreTorrent`

### 4a. HDR and Dolby Vision Badge Detection

Yes — you absolutely can detect HDR type and show accurate badges. There are two levels of detection, and both work:

**Level 1: Filename parsing (instant, before download)**

Scene release groups follow rigid naming conventions. Parse the torrent title string with regex to extract HDR metadata. The patterns used by the scene and TRaSH Guides:

```swift
public enum HDRType: String, Sendable {
    case dolbyVisionWithHDR10  = "DV/HDR10"    // most compatible, has fallback
    case dolbyVisionOnly       = "Dolby Vision" // Profile 5, no HDR10 fallback
    case hdr10Plus             = "HDR10+"
    case hdr10                 = "HDR10"
    case hdr                   = "HDR"          // generic, unspecified standard
    case hlg                   = "HLG"
}

public enum AudioFormat: String, Sendable {
    case dolbyAtmos  = "Atmos"
    case dtsX        = "DTS:X"
    case truehd      = "TrueHD"
    case dtshd       = "DTS-HD"
    case eac3        = "EAC3"
    case aac         = "AAC"
}

struct ReleaseParser {
    // HDR detection — ordered from most specific to least
    static func parseHDR(from title: String) -> HDRType? {
        let t = title.lowercased()
        // Dolby Vision with HDR10 fallback (Profile 8, most common)
        if matches(t, pattern: #"(?=.*\b(dv|dovi|dolby\.?vision)\b)(?=.*\bhdr10?\b)"#) {
            return .dolbyVisionWithHDR10
        }
        // Dolby Vision only (Profile 5)
        if matches(t, pattern: #"\b(dv|dovi|dolby[\s.]?vision)\b"#) {
            return .dolbyVisionOnly
        }
        // HDR10+ (dynamic metadata, not DV)
        if matches(t, pattern: #"\bhdr10[+]|hdr10plus\b"#) {
            return .hdr10Plus
        }
        // HDR10 (static, most common)
        if matches(t, pattern: #"\bhdr10\b"#) {
            return .hdr10
        }
        // Generic HDR tag
        if matches(t, pattern: #"\bhdr\b"#) {
            return .hdr
        }
        // HLG (broadcast standard)
        if matches(t, pattern: #"\bhlg\b"#) {
            return .hlg
        }
        return nil
    }

    static func parseCodec(from title: String) -> VideoCodec {
        let t = title.lowercased()
        if t.contains("av1")              { return .av1 }
        if t.contains("x265") || t.contains("h265") || t.contains("hevc") { return .h265 }
        if t.contains("x264") || t.contains("h264") || t.contains("avc")  { return .h264 }
        return .h264 // safe default
    }

    static func parseQuality(from title: String) -> VideoQuality {
        let t = title.lowercased()
        if t.contains("2160") || t.contains("4k") || t.contains("uhd") { return .p2160 }
        if t.contains("1080")                                            { return .p1080 }
        if t.contains("720")                                             { return .p720 }
        return .p1080
    }
}
```

This covers ~97% of real torrent titles accurately. Examples:
- `"Movie.2023.2160p.BluRay.DV.HDR10.H265-GROUP"` → `.dolbyVisionWithHDR10`
- `"Movie.2023.2160p.DOVI.H265-GROUP"` → `.dolbyVisionOnly`
- `"Movie.2023.2160p.BluRay.HDR10+-GROUP"` → `.hdr10Plus`
- `"Movie.2023.1080p.BluRay.HDR.H264-GROUP"` → `.hdr`

**Level 2: ffprobe metadata (after download begins, definitive)**

Once the torrent metadata is resolved (BEP-9) and the first few pieces are downloaded, run `ffprobe -v quiet -print_format json -show_streams` on the partially-downloaded file. Parse the `side_data_list` in the video stream:

```swift
// DOVI configuration record in ffprobe output:
// "side_data_type": "DOVI configuration record"
// → confirmed Dolby Vision

// "color_transfer": "smpte2084" + "color_primaries": "bt2020"
// → confirmed HDR (HDR10 or HDR10+)

// "side_data_type": "HDR Dynamic Metadata SMPTE2094-40"  
// → confirmed HDR10+
```

Update the badge on the TorrentResult once ffprobe confirms or corrects the filename parse. This two-pass approach means badges appear instantly (from filename) and are then confirmed/corrected by real metadata.

### 4b. Full `TorrentResult` model

```swift
public struct TorrentResult: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let magnetURI: String
    public let quality: VideoQuality        // .p720, .p1080, .p2160
    public let hdrType: HDRType?            // nil = SDR
    public let hdrConfidence: HDRConfidence // .fromFilename | .fromMetadata
    public let codec: VideoCodec            // .h264, .h265, .av1
    public let audioFormat: AudioFormat?    // .dolbyAtmos, .truehd, etc.
    public let source: VideoSource          // .bluray, .webdl, .webrip, .hdcam
    public let sizeBytes: Int64
    public let seeders: Int
    public let leechers: Int
    public let uploadDate: Date
    public let trackerSource: TrackerSource // .yts, .jackett(indexer: "1337x"), .tpb
}
```

### 4c. Torrent search aggregation

```
TorrentSearchAggregator
├── YTSClient         → yts.mx/api/v2/list_movies.json  (primary, best for movies)
├── JackettClient     → localhost:9117/api/v2.0/indexers/all/results  (optional, power user)
└── TorrentAPIClient  → torrent-api-py instance (optional, self-hosted scraper)
```

Search flow:
1. Fire YTS and Jackett requests concurrently via `withTaskGroup`
2. Merge results, deduplicate by infohash
3. Sort by: quality (desc) → seeders (desc) → source rank
4. Emit results as an `AsyncStream<[TorrentResult]>` so the UI populates progressively

YTS results already include seeder/leecher counts. Jackett results (Torznab format) include them in the XML/JSON response under `<torznab:attr name="seeders">`.

### 4d. Streaming architecture

```
swift-torrent Session
    ↓ (piece downloaded)
DiskPieceStore (writes to temp file, holds only ±2 pieces in RAM)
    ↓
StreamingHTTPServer (NIO, ephemeral port)
    ↓ (HTTP range requests)
AVPlayer(url: http://127.0.0.1:{port}/stream)
```

The streaming server responds to `Range: bytes=X-Y` headers. AVPlayer uses range requests heavily for seeking — getting this right is what enables instant seek without full download.

For MKV containers: launch `ffmpeg -i input.mkv -c copy -movflags frag_keyframe+empty_moov output.mp4` as a `Process` piped to a temp file. This is a container remux — bitwise identical video/audio data, just re-packaged. Fast (limited by disk I/O, not CPU). Feed the MP4 temp file to the streaming server.

### 4e. Jackett sidecar

```swift
actor JackettSidecar {
    private var process: Process?
    private let port: Int = 9117
    private let installPath = URL.applicationSupportDirectory
        .appending(path: "MovieBox/jackett", directoryHint: .isDirectory)

    func launch() async throws {
        guard !isRunning else { return }
        let proc = Process()
        proc.executableURL = installPath.appending(path: "jackett")
        proc.arguments = ["--NoUpdates", "--Port", "\(port)"]
        proc.standardOutput = Pipe()   // capture logs
        proc.standardError = Pipe()
        try proc.run()
        process = proc
        // Health-check loop: ping /api/v2.0/indexers every 5s, restart on failure
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}
```

---

## 5. Package: `CorePlayer`

### 5a. Liquid Glass player overlay (Tahoe)

The player HUD is the crown jewel. On Sequoia (15): use `.ultraThinMaterial` + manual border overlay. On Tahoe (26): use the native `.glassEffect()` modifier — it's automatic.

```swift
// DesignSystem — adaptive glass modifier
struct AdaptiveGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular.interactive())
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        }
    }
}
```

The transport bar uses `GlassEffectContainer` on Tahoe so the scrubber thumb, time labels, and buttons all share a single morphing glass surface — they merge and separate as the HUD animates in/out. On Sequoia it falls back to individual `.ultraThinMaterial` panels.

### 5b. HDR support

```swift
// In AVPlayerLayerView (NSViewRepresentable)
override func makeNSView(context: Context) -> NSView {
    let view = NSView()
    let layer = AVPlayerLayer(player: player)
    
    // Enable Extended Dynamic Range passthrough
    layer.wantsExtendedDynamicRangeContent = true
    
    view.layer = layer
    view.wantsLayer = true
    return view
}

// Check display capability for badge UI
var displaySupportsHDR: Bool {
    let maxEDR = NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
    return maxEDR > 1.0
}
```

AVFoundation handles HDR10, Dolby Vision (Profile 5, 7, 8), HDR10+, and HLG natively on Apple Silicon with hardware decode. On Intel Macs, HEVC is software-decoded but still plays correctly.

Important: Dolby Vision Profile 5 (no HDR10 fallback) in MKV containers may not decode with full DV tone mapping on macOS — it will play but may fall back to HDR10. Profile 8 (with HDR10 fallback) always works correctly. Reflect this in the badge with a subtle warning: `DV` with a `!` if Profile 5 detected.

### 5c. Quality switcher

```swift
// In PlayerViewModel
func switchQuality(to result: TorrentResult) async {
    let savedPosition = player.currentTime()
    
    // Stop current stream
    await torrentEngine.stopCurrent()
    streamingServer.reset()
    
    // Start new torrent
    let streamURL = try await torrentEngine.startStreaming(magnet: result.magnetURI)
    
    // Replace player item, seek to saved position once buffer ready
    let item = AVPlayerItem(url: streamURL)
    player.replaceCurrentItem(with: item)
    
    // Observe isPlaybackLikelyToKeepUp, then seek
    await waitForBuffer(item: item)
    player.seek(to: savedPosition)
}
```

### 5d. Player controls keyboard map

| Key | Action |
|---|---|
| `Space` | Play / Pause |
| `←` / `→` | Seek ±10s |
| `⌘←` / `⌘→` | Seek ±60s |
| `↑` / `↓` | Volume ±10% |
| `M` | Mute |
| `F` | Toggle fullscreen |
| `Esc` | Exit fullscreen |
| `S` | Cycle subtitle track |
| `Q` | Open quality picker |
| `C` | Cycle audio track |

---

## 6. Package: `DesignSystem`

### 6a. Liquid Glass component catalogue

All components implement the `AdaptiveGlass` modifier pattern — they look correct on both Sequoia and Tahoe automatically.

```
DesignSystem/Sources/DesignSystem/
├── Glass/
│   ├── AdaptiveGlass.swift          ← The adaptive modifier (Sequoia/Tahoe branch)
│   ├── GlassCard.swift              ← Generic floating panel
│   ├── GlassBadge.swift             ← Small pill badge (for HDR, quality tags)
│   └── GlassButton.swift            ← Circular action button (play, etc.)
├── Tokens/
│   ├── Colors.swift
│   └── Typography.swift
├── Components/
│   ├── MoviePosterCard.swift
│   ├── HeroCarousel.swift
│   ├── HorizontalMovieRow.swift
│   ├── TorrentResultRow.swift        ← With HDR/DV badges inline
│   ├── RatingOverlay.swift           ← ❤️ / 👎 / 🔥 action panel
│   └── LoadingShimmer.swift
└── Animations/
    └── SpringPresets.swift
```

### 6b. HDR badge system

Badges are `GlassBadge` instances — small pill shapes with glass material and colored labels. Each HDR type gets a distinct color to visually differentiate at a glance:

| Badge | Label | Color |
|---|---|---|
| Dolby Vision + HDR10 | `DV · HDR10` | `#5B8AF0` (blue-violet) |
| Dolby Vision only | `Dolby Vision` | `#6E40C9` (purple) |
| HDR10+ | `HDR10+` | `#E8A020` (amber) |
| HDR10 | `HDR10` | `#3DAA6F` (green) |
| HDR | `HDR` | `#3DAA6F` (green, dimmer) |
| HLG | `HLG` | `#888888` (grey) |
| SDR | *(no badge)* | — |

Audio badges (shown alongside):

| Badge | Label | Color |
|---|---|---|
| Dolby Atmos | `Atmos` | `#1A6FE8` (blue) |
| DTS:X | `DTS:X` | `#444` (dark) |
| TrueHD | `TrueHD` | `#C0392B` (red) |

These appear in three places:
1. The `TorrentResultRow` (full badges, one line)
2. The player overlay top-right (compact: `4K · DV · HDR10 · Atmos`)
3. The movie detail "Available Versions" grouped header

### 6c. Torrent result row layout

```
┌─────────────────────────────────────────────────────────────────────┐
│  [4K]  [DV · HDR10]  [Atmos]  [H.265]  [BluRay]   23.4 GB         │
│  ↑ 1,204 seeders    ↓ 43 leechers    YTS · 2 days ago              │
│                                              [▶ Stream]  [⬇ Save]  │
└─────────────────────────────────────────────────────────────────────┘
```

Seeder count coloring:
- `> 500` → `Color.green`
- `50–500` → `Color.yellow`
- `10–50` → `Color.orange`
- `< 10` → `Color.red`

---

## 7. Package: `CoreML_Engine`

### Rating values
- 👎 Dislike → `-1.0`
- ❤️ Like → `+1.0`
- 🔥 Double-like → `+2.0`

### Phase 1: Genre affinity (instant, 0 ratings needed)

Compute a genre affinity vector: a `[Int: Float]` dictionary mapping genre ID to a running weighted sum of ratings. Normalize to `[-1, 1]`. Score each unrated movie as `dot(movieGenreVector, affinityVector)`. This works from the first rating and is O(n×g) where n = movie count and g = genre count (~20). Sub-millisecond.

### Phase 2: `MLRecommender` (after 20+ ratings)

Train on-device via `MLJob` in a detached `Task`. The model trains in `~500ms` for small datasets and writes to `Application Support/MovieBox/recommender.mlmodel`. Load with `try MLModel(contentsOf: modelURL)`. Blend with genre affinity at 60/40 (ML/content) using `HybridRanker`.

---

## 8. Package: `CoreStorage` — SwiftData Schemas

```swift
@Model class MovieRecord {
    @Attribute(.unique) var tmdbId: Int
    var title: String
    var posterPath: String?
    var genres: [Int]
    var watchlistAddedAt: Date?
    var lastWatchedAt: Date?
    var playbackPositionSeconds: Double = 0
    var watchedFraction: Double = 0   // 0.0–1.0, for "continue watching"
}

@Model class RatingRecord {
    @Attribute(.unique) var tmdbId: Int
    var rating: Float                  // -1.0, +1.0, or +2.0
    var ratedAt: Date
    var genres: [Int]                  // snapshot at rating time
}

@Model class DownloadRecord {
    @Attribute(.unique) var tmdbId: Int
    var magnetURI: String
    var infohash: String
    var quality: String
    var hdrType: String?
    var localFilePath: String?
    var state: DownloadState
    var progressFraction: Double
    var totalBytes: Int64
    var downloadedBytes: Int64
    var pieceBitmap: Data              // for cross-launch resume
    var createdAt: Date
}

@Model class AppSettings {
    // Stored as a single row, queried as a singleton
    var proxyBaseURL: String           // Hono backend URL, empty = call APIs directly
    var jackettAPIKey: String          // stored encrypted via @Attribute(.encrypt)
    var jackettPort: Int = 9117
    var defaultDownloadPath: String
    var preferredQuality: String = "best"
    var preferredAudioLang: String = "en"
    var preferredSubtitleLang: String = "en"
    var enableSeeding: Bool = true
    var maxDownloadSpeedKBps: Int = 0  // 0 = unlimited
    var maxUploadSpeedKBps: Int = 512
    var autoPlayNextEpisode: Bool = false  // future TV shows support
}
```

---

## 9. App Layout — Navigation Architecture

### Window setup

```swift
@main struct MovieBoxApp: App {
    @State private var router = AppRouter()
    @State private var playerState = PlayerState()
    @State private var suggestions = SuggestionService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .environment(playerState)
                .environment(suggestions)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) { }
            MovieBoxCommands(router: router)
        }

        Settings {
            SettingsView()
        }
    }
}
```

### Navigation model

```swift
@Observable class AppRouter {
    enum Route: Hashable {
        case home
        case search(query: String = "")
        case movieDetail(id: Int)
        case downloads
        case myList
    }

    var path: [Route] = []
    var isPlayerPresented: Bool = false
    var activeMovieId: Int?

    func push(_ route: Route) { path.append(route) }
    func pop() { path.removeLast() }
    func presentPlayer(movieId: Int) {
        activeMovieId = movieId
        isPlayerPresented = true
    }
}
```

`RootView` is a `NavigationSplitView` with a compact sidebar (icon + label, hidden by default on launch). The detail column drives from `router.path`. Player is presented as a `fullScreenCover` — it takes over the full window, hides the sidebar, hides the toolbar.

---

## 10. Screen Specifications

### HomeView

Vertically scrollable `LazyVStack(spacing: 48)` containing:

1. **Hero Carousel** (`TabView` with `.page` style, auto-advances 6s)
   - Full-width backdrop, gradient overlay bottom-to-top
   - Title (Display font, 52pt), tagline (20pt, 60% opacity)
   - `▶ Play` (glass button, accent fill) · `+ My List` (glass button, outline)
   - Quality badge if 4K available: `[4K] [DV]` glass pills top-right of backdrop

2. **Continue Watching** row — only shown if `watchedFraction` > 0.05 and < 0.95
   - Progress bar overlaid on poster bottom edge

3. **Suggested For You** row — only after 5+ ratings

4. **Trending This Week** — TMDB weekly trending
5. **Popular Right Now** — TMDB popular
6. **Top Rated of All Time** — TMDB top_rated
7. **Now In Theatres** — TMDB now_playing
8. **Genre rows** × 5 — one per top genres

Each row: `HorizontalMovieRow` with `ScrollView(.horizontal, showsIndicators: false)`. Rows load via independent `Task` — a failed row shows a retry button, no cascading errors.

### MovieDetailView

```
[ ← Back ]

┌────────────────────────────── BACKDROP (blurred, faded bottom) ──────────────────────────────┐
│                                                                                               │
│  [POSTER]   Movie Title (36pt Display)                                          [4K][DV·HDR10]│
│  2023 · 2h 18m · Action · Thriller                                                           │
│  ⭐ 8.4 TMDB    🎬 8.1 IMDB                                                                  │
│                                                                                               │
│  [ ▶ Play Best Quality ]   [ + My List ]   [ ⬇ Download ]   [ ··· ]                        │
│                                                                                               │
└───────────────────────────────────────────────────────────────────────────────────────────────┘

Synopsis text (3 lines, expandable)

Cast ──────────────────────────────────────────────────────────────────────
[ Avatar ] [ Avatar ] [ Avatar ] ...

Available Versions ▼ ─────────────────────────────────────────────────────
  (Expanded: shows TorrentResultRow list, grouped by quality)

More Like This ────────────────────────────────────────────────────────────
```

"Play Best Quality" auto-selects the torrent with highest seeders at the user's preferred max quality.

### TorrentResultsPanel

Appears as an expandable section below synopsis. On expand, fires `TorrentSearchAggregator`. Shows:
- Loading: shimmer rows × 3
- Grouped by quality (4K → 1080p → 720p), each group collapsible
- Within group: sorted by seeders desc
- Each row: `TorrentResultRow` with full badge set, seeder count, size, source, Stream/Download buttons
- Badge confidence indicator: filename badge has a `◦` dot, ffprobe-confirmed badge has a `●` dot

### PlayerView

Full-window. `ZStack`:
- Bottom layer: `AVPlayerLayerView` (fills window, `AVPlayerLayer`)
- Top layer: `PlayerOverlayView` (opacity animated by mouse activity)

`PlayerOverlayView`:
```
┌─ top ─────────────────────────────────────────────────────────┐
│  ← Back     Movie Title (glass pill)          [4K·DV·Atmos]  │
└───────────────────────────────────────────────────────────────┘

                     (video content)

┌─ bottom ──────────────────────────────────────────────────────────────────────────┐
│  [⏮10s] [⏵] [⏭10s]  [🔊]─────  0:42:18 ─────────────────────── 1:58:04         │
│  ════════════════════════════╪══════════════════════════════════                  │
│                         (scrubber with thumbnail strip on hover)                  │
│                                           [Q quality] [S subs] [C audio] [⛶ fs] │
└───────────────────────────────────────────────────────────────────────────────────┘
```

The bottom bar is a single `GlassEffectContainer` on Tahoe with the scrubber and buttons sharing one morphing glass surface.

Thumbnail strip: `AVAssetImageGenerator` extracts frames every 5 seconds as JPEG into a `[CMTime: NSImage]` cache. On scrubber hover, show the nearest frame in a glass popup above the scrubber thumb.

### DownloadsView

Native `List` bound to `@Query var downloads: [DownloadRecord]`:
```
[Poster] The Matrix Reloaded          [1080p] [HDR10] [H.265]
         Downloaded 2h ago · 14.2 GB
         [████████████████████░░] 92%  ↓ 2.4 MB/s
         [ ▶ Watch ]  [ ⏸ Pause ]  [ 🗑 Delete ]
```

Completed items: "Watch" pushes to PlayerView with local `file://` URL — same player, no streaming server.

---

## 11. Hono Backend — Full Route Map

```typescript
// src/index.ts
import { Hono } from 'hono'
import { cache } from 'hono/cache'
import tmdb from './routes/tmdb'
import omdb from './routes/omdb'
import subtitles from './routes/subtitles'

const app = new Hono<{ Bindings: Env }>()

app.use('*', async (c, next) => {
  // Simple bearer token auth so only MovieBox app can call this
  const token = c.req.header('X-MovieBox-Token')
  if (token !== c.env.APP_SECRET) return c.json({ error: 'unauthorized' }, 401)
  await next()
})

app.route('/api/tmdb', tmdb)
app.route('/api/omdb', omdb)
app.route('/api/subtitles', subtitles)

export default app
```

```typescript
// src/routes/tmdb.ts
const tmdb = new Hono<{ Bindings: Env }>()

// Edge cache for stable endpoints
tmdb.use('/genre/*', cache({ cacheName: 'moviebox', cacheControl: 'max-age=86400' }))
tmdb.use('/movie/*/credits', cache({ cacheName: 'moviebox', cacheControl: 'max-age=21600' }))

tmdb.all('/*', async (c) => {
  const path = c.req.path
  const search = new URL(c.req.url).search
  const res = await fetch(`https://api.themoviedb.org/3${path}${search}`, {
    headers: { Authorization: `Bearer ${c.env.TMDB_TOKEN}` },
    cf: { cacheTtl: 1800, cacheEverything: true }
  })
  return new Response(res.body, {
    headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
  })
})

export default tmdb
```

`wrangler.toml` bindings:
```toml
name = "moviebox-proxy"
compatibility_date = "2025-01-01"

[vars]
APP_ENV = "production"

[[kv_namespaces]]
binding = "CACHE_KV"
id = "YOUR_KV_ID"

# Secrets (set via wrangler secret put):
# TMDB_TOKEN
# OMDB_API_KEY
# APP_SECRET
# OPENSUBTITLES_API_KEY
```

The Swift `ProxyBridge` package sends `X-MovieBox-Token` from Keychain on every request. If the backend URL is blank in Settings, it bypasses the proxy and calls APIs directly with local Keychain keys.

---

## 12. Auto-Updater: Sparkle 2 + GitHub Releases

Sparkle is verified via EdDSA signatures and Apple Code Signing, supports delta updates (only patching changed files), and is completely seamless — it uses your app's own icons and name with no mention of Sparkle.

### SPM dependency

```swift
// In App target Package.swift or Xcode SPM panel:
.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
```

### Setup in app

```swift
// MovieBoxApp.swift
import Sparkle

@main struct MovieBoxApp: App {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup { RootView() }
        Settings {
            SettingsView(updater: updaterController.updater)
        }
    }
}

// In SettingsView — manual update check
Button("Check for Updates") {
    updaterController.updater.checkForUpdates()
}
```

### `Info.plist` keys

```xml
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/yourname/moviebox/main/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>YOUR_BASE64_ED25519_PUBLIC_KEY</string>
<key>SUEnableAutomaticChecks</key>
<true/>
```

### GitHub Actions release pipeline

```yaml
# .github/workflows/release.yml
name: Release
on:
  push:
    tags: ['v*']

jobs:
  build:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Build & Archive
        run: |
          xcodebuild archive \
            -scheme MovieBox \
            -archivePath build/MovieBox.xcarchive \
            -configuration Release
          xcodebuild -exportArchive \
            -archivePath build/MovieBox.xcarchive \
            -exportPath build/export \
            -exportOptionsPlist ExportOptions.plist

      - name: Sign for Sparkle
        run: |
          # generate_appcast signs the zip with EdDSA private key from Secrets
          echo "${{ secrets.SPARKLE_PRIVATE_KEY }}" > sparkle_private_key
          ./Packages/sparkle/bin/sign_update build/export/MovieBox.app.zip \
            --ed-key-file sparkle_private_key

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v1
        with:
          files: |
            build/export/MovieBox.zip
            appcast.xml
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

`appcast.xml` is hosted on the `main` branch at the repo root. `generate_appcast` tool creates it automatically from the release artifacts. Sparkle checks it on launch (configurable interval) and prompts the user with a native update sheet.

---

## 13. Efficiency Checklist — for the Coding Agent

This is the section to revisit on every PR. If any item is violated, fix it before merging.

### Memory
- [ ] `NSCache` with explicit `countLimit` and `totalCostLimit` for image cache
- [ ] Torrent pieces: max 2 in RAM at once, rest on disk
- [ ] `AVPlayerLayer` reused across playback sessions — never recreate from scratch
- [ ] Poster images sized to display size (use TMDB's `w342` path, not `original`)
- [ ] `LazyVStack` / `LazyHStack` for all scroll views — never `VStack` inside `ScrollView`

### CPU
- [ ] All network I/O on background actors — never on `@MainActor`
- [ ] Image decoding on background thread: `DispatchQueue.global().async` or `Task.detached`
- [ ] ffprobe runs in detached `Task` — never blocks UI
- [ ] MLRecommender training in `Task.detached(priority: .background)`
- [ ] `AVAssetImageGenerator` frames extracted lazily — only when scrubber is hovered

### Network
- [ ] HTTP/2 with connection coalescing for TMDB (single `URLSession` instance)
- [ ] Deduplicate in-flight image requests (custom `ImageLoader` actor with `continuations: [URL: [CheckedContinuation]]`)
- [ ] Backend proxy with `cf: { cacheEverything: true }` for stable endpoints
- [ ] Jackett queries cancelled if user navigates away before results arrive

### Disk
- [ ] Piece files in `tmp/moviebox-stream/` — auto-cleaned on app quit and on OS pressure via `NSFileProtectionNone` + `FileManager.removeItem` in termination handler
- [ ] SwiftData `ModelContext` never accessed from a background thread directly — use `ModelActor` for background operations

### SwiftUI rendering
- [ ] `@Observable` instead of `ObservableObject` everywhere (Swift 5.9+)
- [ ] No `AnyView` type erasure in hot paths (scroll views, list cells)
- [ ] `.drawingGroup()` on poster card hover shadows to rasterize the composite
- [ ] `equatable()` on cells that receive frequent updates (seeder count ticks)

---

## 14. Implementation Phases (Revised)

### Phase 1 — Skeleton + Data (Weeks 1–2)
- [ ] Xcode project + 6 packages wired up
- [ ] `CoreMetadata`: TMDB actor, all endpoints, Movie model, image cache
- [ ] `CoreStorage`: SwiftData schemas + migrations
- [ ] `DesignSystem`: tokens, `MoviePosterCard`, `HorizontalMovieRow`, shimmer
- [ ] `HomeView`: hero + 4 rows, navigation working
- [ ] `MovieDetailView`: backdrop, metadata, synopsis, cast

### Phase 2 — Torrent Search (Week 3)
- [ ] `YTSClient` with full TorrentResult parsing
- [ ] `ReleaseParser`: filename HDR/codec/quality/audio detection
- [ ] `TorrentResultsPanel` on MovieDetailView with badges
- [ ] `JackettClient` (optional — gate behind Settings toggle)
- [ ] Seeder count coloring, badge system in `DesignSystem`

### Phase 3 — Streaming (Week 4)
- [ ] `TorrentEngine` wrapping swift-torrent
- [ ] `DiskPieceStore` — piece-to-disk writing, sequential priority
- [ ] `StreamingHTTPServer` — NIO HTTP server with range requests
- [ ] MKV → MP4 remux via bundled ffmpeg binary
- [ ] Basic `CorePlayer`: AVPlayer + `AVPlayerLayerView` + playback
- [ ] End-to-end: tap Stream → magnet resolves → NIO server → AVPlayer

### Phase 4 — Player Polish (Week 5)
- [ ] Full custom overlay with glass HUD (Sequoia + Tahoe adaptive)
- [ ] Scrubber with thumbnail strip
- [ ] Quality switcher (mid-playback magnet swap)
- [ ] HDR badge in player (`4K · DV · HDR10 · Atmos`)
- [ ] ffprobe HDR confirmation pass
- [ ] `displaySupportsHDR` check — badge greys out on non-HDR displays
- [ ] Subtitle download (OpenSubtitles) + SRT rendering
- [ ] Keyboard shortcuts wired

### Phase 5 — Downloads + ML (Week 6)
- [ ] `DownloadManager` full state machine
- [ ] `DownloadsView` with progress UI
- [ ] Offline `PlayerView` path (local file URL)
- [ ] Rating overlay (❤️ / 👎 / 🔥)
- [ ] `GenreAffinityEngine` — content-based suggestions instant
- [ ] "Suggested For You" row on HomeView

### Phase 6 — Backend + ML Advanced (Week 7)
- [ ] Hono proxy: TMDB + OMDb + subtitles routes
- [ ] Cloudflare Workers deployment + KV cache
- [ ] `ProxyBridge` package + fallback to direct
- [ ] `MLRecommender` training pipeline (after 20+ ratings)
- [ ] `HybridRanker` blending ML + genre affinity

### Phase 7 — Shipping (Week 8)
- [ ] Sparkle 2 integration
- [ ] GitHub Actions release pipeline
- [ ] `generate_appcast` + EdDSA key generation documented
- [ ] `appcast.xml` on main branch
- [ ] macOS Notarization via `notarytool` in CI
- [ ] `ExportOptions.plist` for Developer ID distribution
- [ ] PiP (`AVPictureInPictureController`) — bonus if time allows
- [ ] README + install instructions

---

## 15. External Dependencies Summary

| Dependency | Source | Purpose |
|---|---|---|
| `warppipe/swift-torrent` | SPM | BitTorrent engine (pure Swift) |
| `apple/swift-nio` | SPM | Local HTTP streaming server |
| `apple/swift-collections` | SPM | `OrderedDictionary` for piece map |
| `sparkle-project/Sparkle` | SPM | Auto-updater |
| `ffmpeg` binary | Bundled in app (macOS arm64 + x86_64) | MKV→MP4 remux, ffprobe metadata |
| Jackett | User-installed sidecar | Multi-tracker torrent search |
| TMDB API | `api.themoviedb.org` | Movie metadata (free tier) |
| OMDb API | `omdbapi.com` | IMDB ratings (free tier, 1k/day) |
| OpenSubtitles | `api.opensubtitles.com` | Subtitle download |

Total Swift package count: 4. No JavaScript. No Electron. No WebView. Pure native.

---

*Hand this document to your coding agent as the authoritative spec for MovieBox. Every module, file, API, badge, and phase is fully defined. Build Phase 1 first, validate end-to-end data flow, then layer in torrent streaming in Phase 3.*
