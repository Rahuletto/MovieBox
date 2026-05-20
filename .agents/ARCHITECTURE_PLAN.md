# MovieBox — macOS Native Architecture Plan
> Codename: MovieBox  
> Stack: Swift 6 · SwiftUI · AVFoundation · Core ML  
> Target: macOS Sequoia (15+) with Liquid Glass on macOS Tahoe (26+)  
> Distribution: GitHub Releases + Sparkle auto-updater  
> Backend: Hono/TypeScript Edge Proxy on Cloudflare Workers

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
moviebox/                            ← Repository root
├── App/                             ← Xcode project root
│   ├── MovieBox/                    ← Thin App container
│   │   ├── MovieBoxApp.swift        ← @main Entry point, scene setup, DI root
│   │   ├── AppRouter.swift          ← Router state machine
│   │   ├── Views/                   ← Split View folder
│   │   │   ├── Home/                ← Home feed, hero carousel
│   │   │   ├── Detail/              ← MovieDetailView, TorrentResultsPanel
│   │   │   ├── Downloads/           ← DownloadsView (SwiftData bound)
│   │   │   ├── Search/              ← SearchView with progressive SSE search
│   │   │   └── Settings/            ← Native Preferences tabs
│   │   └── Components/              ← App-specific UI controls
│   │
│   ├── MovieBoxCore/                ← Core package: services, bootstrap, caching
│   │   ├── Sources/MovieBoxCore/
│   │   │   ├── AppBootstrap.swift   ← App initialization lifecycle
│   │   │   ├── AppServices.swift    ← DI service registry
│   │   │   ├── CatalogLoader.swift  ← Handles home feed rows
│   │   │   ├── LogStore.swift       ← In-memory & file logging service
│   │   │   └── TorrentPlaybackCoordinator.swift ← Manages stream session & player view sync
│   │
│   ├── MovieBoxDetail/              ← Detail view package: loaders, relevance matching
│   │   ├── Sources/MovieBoxDetail/
│   │   │   ├── MovieDetailLoader.swift ← Fetches unified detail JSON
│   │   │   ├── MovieDetailTorrentSearch.swift ← Triggers search & progressive result parsing
│   │   │   └── TorrentMovieRelevanceFilter.swift ← Computes Levenshtein matches
│   │
│   ├── CoreStreaming/               ← BitTorrent engine package
│   │   ├── Sources/CoreStreaming/
│   │   │   ├── DHT/                 ← BEP 5 DHT client (compact formats)
│   │   │   ├── Trackers/            ← HTTP & UDP Tracker client
│   │   │   ├── PieceManager.swift   ← Block & piece sequential priority download
│   │   │   ├── PieceStore.swift     ← Writing piece chunks to disk
│   │   │   ├── StreamSession.swift  ← Streaming state machine
│   │   │   └── HTTPRangeServer.swift ← Ephemeral range server for AVPlayer
│   │
│   ├── CoreMetadata/                ← TMDB/OMDb API mapping schemas & loaders
│   ├── CoreTorrent/                 ← Torrent metadata result model & indexers registry
│   ├── CorePlayer/                  ← AVPlayer abstraction, custom controls, subtitles
│   ├── CoreMLEngine/                ← Hybrid rating ranker and genre affinity
│   ├── CoreStorage/                 ← SwiftData storage schemas and context helpers
│   ├── DesignSystem/                ← Adaptive glass modifiers, glass badges, colors
│   └── MovieBox.xcodeproj
│
├── Backend/                         ← Hono/TypeScript Edge Proxy (Cloudflare Workers)
│   ├── src/
│   │   ├── index.ts                 ← App entry point and Hono router definitions
│   │   ├── tmdb-upstream.ts         ← TMDB edge client and caching rules
│   │   ├── rotten-tomatoes.ts       ← Rotten Tomatoes HTML scraper (score + trailers)
│   │   ├── subtitle-guard.ts        ← Subtitle hosts validation & Subf2m scrape helpers
│   │   ├── trailer-resolve.ts       ← YouTube/Piped trailer stream resolver
│   │   ├── kv-cache.ts              ← Cloudflare KV namespace helper functions
│   │   └── torrent/                 ← Torrent indexer registry & search algorithms
│   │       ├── search.ts            ← Concurrent search
│   │       └── search-stream.ts     ← Server-Sent Events (SSE) progressive streamer
│   ├── wrangler.toml
│   └── package.json
```

---

## 2. Hono Backend Router Design & Edge Caching

The backend is built with Hono on Cloudflare Workers. It secures API keys, edge-caches heavy TMDB/Fanart queries, aggregates details into a single round-trip, streams torrent listings via Server-Sent Events, scrapes Rotten Tomatoes, and extracts subtitle packages.

### Unified Title Bundle Endpoint (`GET /api/title/:kind/:id`)
Fetches TMDB details + credits + similar + videos + Fanart logos + OMDB ratings + Rotten Tomatoes Tomatometer/trailers in one client RTT. Warm requests serve instantly from KV.

```typescript
// Backend/src/index.ts - GET /api/title/:kind/:id
app.get('/api/title/:kind/:id', async (c) => {
  const { kind, id } = c.req.param()
  const cacheKey = `title:${kind}:${id}`
  
  // KV edge cache
  const cached = await kvGet(c.env.MOVIEBOX_CACHE, cacheKey)
  if (cached) {
    return c.json(JSON.parse(cached), {
      headers: { 'X-Cache': 'HIT', 'Cache-Control': 'public, max-age=21600' }
    })
  }

  // Fetch TMDB with appends in parallel
  const append = kind === 'movie' ? 'credits,similar,external_ids,videos,release_dates' : 'credits,similar,external_ids,videos,content_ratings'
  const detail = await fetchTmdb(c, `${kind}/${id}?append_to_response=${append}`)

  // OMDb & Rotten Tomatoes tasks in parallel
  const extIds = detail.external_ids || {}
  const title = detail.title || detail.name
  const year = (detail.release_date || detail.first_air_date || '').toString().slice(0, 4)

  const omdbTask = fetchOmdb(c, extIds.imdb_id, title, year, kind)
  const rtTask = fetchRottenTomatoes(c, title, year, extIds.imdb_id, kind)
  const fanartTask = fetchFanartLogo(c, extIds.imdb_id || extIds.tvdb_id, kind)

  const [omdb, rtBundle, fanart] = await Promise.all([omdbTask, rtTask, fanartTask])

  // Proxy the Fanart logo through `/img` for edge caching
  const proxiedLogo = proxyImage(c, pickBestLogo(fanart))
  detail.moviebox_logo = proxiedLogo

  // Merge OMDb and Rotten Tomatoes details
  detail.moviebox_enrichment = mergeEnrichment(omdb, rtBundle)

  // Write back to KV
  await kvPut(c.env.MOVIEBOX_CACHE, cacheKey, JSON.stringify(detail), { expirationTtl: 21600 })
  return c.json(detail, { headers: { 'X-Cache': 'MISS' } })
})
```

---

## 3. Package: `MovieBoxCore`

This package coordinates global application startup, DI services, network reachability, logging, and playback orchestration.

### Services Registry (`AppServices.swift`)
Maintains singleton instances of services to support clean Dependency Injection.
```swift
public final class AppServices: Sendable {
    public static let shared = AppServices()
    
    public let logStore = LogStore()
    public let catalogLoader = CatalogLoader()
    public let downloadService = DownloadPersistenceService()
    public let playbackCoordinator = TorrentPlaybackCoordinator()
}
```

### Catalog Loading & Cache (`CatalogLoader.swift`)
Executes parallel fetching of the Home feed. Implements `CatalogCache` which caches trending, popular, and genre lists in memory for exactly **5 minutes** (300 seconds) to avoid redundant backend requests on screen switching.

```swift
public actor CatalogLoader {
    private var inMemoryCache: [String: (data: [Movie], timestamp: Date)] = [:]
    private let ttl: TimeInterval = 300 // 5 minutes

    public func fetchRow(for category: CatalogCategory, urlSession: URLSession) async throws -> [Movie] {
        let cacheKey = category.rawValue
        if let cached = inMemoryCache[cacheKey], Date().timeIntervalSince(cached.timestamp) < ttl {
            return cached.data
        }
        
        let path = category.apiPath
        let items: [Movie] = try await requestBackend(path: path, urlSession: urlSession)
        inMemoryCache[cacheKey] = (items, Date())
        return items
    }
}
```

---

## 4. Package: `MovieBoxDetail`

This package isolates movie detail retrieval, TV episode indexing, and client-side relevance matching of torrent results.

### Torrent Curation and Relevance Filter (`TorrentMovieRelevanceFilter.swift`)
To prevent the client from downloading incorrect torrent releases, search results undergo strict sanitization:
1. **Title Token Comparison**: Splits the TMDB movie title and release name into alphanumeric tokens.
2. **Levenshtein Distance**: Matches parsed title strings and filters out matches with a Levenshtein edit distance greater than 3.
3. **Year Check**: Releases must match the TMDB release year (or ±1 year for late December releases).
4. **Resolution Curation**: Groups torrents by `VideoQuality` (.p2160, .p1080, .p720) and collates them, sorting by seeders descending.

---

## 5. Package: `CoreStreaming` (BitTorrent Protocol Engine)

This package contains a pure Swift implementation of the BitTorrent wire protocol, UDP tracker interaction, BEP 5 DHT support, and an HTTP range server.

### 5a. DHT Protocol compliance (BEP 5)
Standardized node and peer encoding via `DHTCodec`. Handles compact representations of peer and node strings:
- **Compact Peers**: 6 bytes (4 bytes IPv4, 2 bytes Port).
- **Compact Nodes**: 26 bytes (20 bytes Node ID, 4 bytes IPv4, 2 bytes Port).
DHT lookup works concurrently using recursive routing table searches.

### 5b. Piece & Block Writing (`PieceStore.swift` & `PieceManager.swift`)
AVPlayer requires chunks of bytes sequentially to prevent stuttering.
- **PieceManager**: Prioritizes downloading the first 10 pieces (head) and last 5 pieces (tail) of the video file to populate the index and file headers. The remaining pieces are requested sequentially from the current playback playhead position.
- **PieceStore**: Writes received blocks (typically 16KB) directly to disk using `FileHandle` write bounds. Block writes map to absolute offsets:
  `let absoluteOffset = UInt64(pieceIndex) * UInt64(pieceSize) + UInt64(blockOffset)`
  Once all blocks of a piece are written, the PieceStore performs a SHA-1 hash check against the torrent's info dictionary and updates its `pieceBitmap`.

### 5c. HTTP Range Server (`HTTPRangeServer.swift`)
Listens on an ephemeral local port (e.g., `127.0.0.1:8080`) and intercepts range requests from `AVPlayer`.
- Range Header parsing: Extracts `Range: bytes=start-end` values.
- Blocks on reads: If `AVPlayer` requests bytes from a piece that has not yet been verified, the server calls the PieceStore's blocking `read` method, which suspends the current task until the background peer wire loop completes the verification of that piece.

```swift
// CoreStreaming/HTTPRangeServer.swift
func handleRequest(_ request: HTTPRequest, responseWriter: HTTPResponseWriter) async {
    guard let rangeHeader = request.headers["Range"] else {
        // Serve headers only or full file (unseekable)
        return
    }
    
    let (start, end) = parseRangeHeader(rangeHeader, totalSize: torrentSize)
    responseWriter.writeHeader(status: .partialContent, headers: [
        "Content-Range": "bytes \(start)-\(end)/\(torrentSize)",
        "Content-Length": "\(end - start + 1)",
        "Content-Type": "video/mp4"
    ])
    
    var offset = start
    while offset <= end {
        let chunkLength = min(UInt64(128 * 1024), end - offset + 1)
        // Suspends here if piece is downloading
        let data = try await pieceStore.read(offset: offset, length: Int(chunkLength))
        try await responseWriter.writeBody(data)
        offset += chunkLength
    }
}
```

---

## 6. Package: `CorePlayer`

Custom SwiftUI overlay player.

### HDR Passthrough View (`AVPlayerLayerView.swift`)
Direct NSView wrapper to support Extended Dynamic Range (EDR) rendering:
```swift
public final class AVPlayerLayerView: NSViewRepresentable {
    private let player: AVPlayer

    public init(player: AVPlayer) {
        self.player = player
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.wantsExtendedDynamicRangeContent = true // Crucial for Dolby Vision / HDR10
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}
```

### Subtitle Sub-Sync Engine
Supports fetching `.srt` sidecar subtitles (via backend subf2m scraper). Tracks `player.addPeriodicTimeObserver` ticks and renders matching captions synchronously in a overlay glass banner.

---

## 7. Package: `CoreStorage` (SwiftData Schemas)

Core persistence layer.

```swift
@Model 
public final class MovieRecord {
    @Attribute(.unique) public var tmdbId: Int
    public var title: String
    public var mediaKind: String // "movie" or "tv"
    public var posterPath: String?
    public var genres: [Int]
    public var watchlistAddedAt: Date?
    public var lastWatchedAt: Date?
    public var playbackPositionSeconds: Double = 0
    public var watchedFraction: Double = 0
    
    public init(tmdbId: Int, title: String, mediaKind: String, posterPath: String?, genres: [Int]) {
        self.tmdbId = tmdbId
        self.title = title
        self.mediaKind = mediaKind
        self.posterPath = posterPath
        self.genres = genres
    }
}

@Model 
public final class DownloadRecord {
    @Attribute(.unique) public var infoHash: String
    public var tmdbId: Int
    public var mediaKind: String
    public var title: String
    public var magnetURI: String
    public var quality: String
    public var storageDirectory: String
    public var state: String
    public var progressFraction: Double
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var pieceBitmap: Data
    public var createdAt: Date

    public init(infoHash: String, tmdbId: Int, mediaKind: String, title: String, magnetURI: String, quality: String, storageDirectory: String) {
        self.infoHash = infoHash
        self.tmdbId = tmdbId
        self.mediaKind = mediaKind
        self.title = title
        self.magnetURI = magnetURI
        self.quality = quality
        self.storageDirectory = storageDirectory
        self.state = "pending"
        self.progressFraction = 0.0
        self.totalBytes = 0
        self.downloadedBytes = 0
        self.pieceBitmap = Data()
        self.createdAt = Date()
    }
}
```

---

## 8. UI Badge Specifications & Design System

Liquid Glass design language details.

### Video Attributes Regex Parsing (`ReleaseParser.swift`)
```swift
struct ReleaseParser {
    static func parseHDR(from title: String) -> HDRType? {
        let t = title.lowercased()
        if matches(t, pattern: #"\b(dv|dovi|dolby.?vision)\b.*\b(hdr|hdr10)\b"#) { return .dolbyVisionWithHDR10 }
        if matches(t, pattern: #"\b(dv|dovi|dolby.?vision)\b"#) { return .dolbyVisionOnly }
        if matches(t, pattern: #"\b(hdr10[+]|hdr10plus)\b"#) { return .hdr10Plus }
        if matches(t, pattern: #"\bhdr10\b"#) { return .hdr10 }
        if matches(t, pattern: #"\bhdr\b"#) { return .hdr }
        return nil
    }

    static func parseAudio(from title: String) -> AudioFormat? {
        let t = title.lowercased()
        if matches(t, pattern: #"\b(atmos|truehd.?atmos)\b"#) { return .dolbyAtmos }
        if matches(t, pattern: #"\bdts.?x\b"#) { return .dtsX }
        if matches(t, pattern: #"\btruehd\b"#) { return .truehd }
        if matches(t, pattern: #"\bdts.?hd\b"#) { return .dtshd }
        return nil
    }
}
```

### Visual badge styling

```
┌─────────────────┬───────────┬────────────────────────────────┐
│ Badge Type      │ Label Text│ Color Hex                      │
├─────────────────┼───────────┼────────────────────────────────┤
│ Dolby Vision    │ DV        │ #6E40C9 (Vibrant Deep Purple)  │
│ DV + HDR10      │ DV·HDR10  │ #5B8AF0 (Royal Blue-Violet)    │
│ HDR10+          │ HDR10+    │ #E8A020 (Bright Amber Gold)    │
│ HDR10 / HDR     │ HDR10     │ #3DAA6F (Smaragdine Green)     │
│ Dolby Atmos     │ Atmos     │ #1A6FE8 (Atmospheric Neon Blue)│
│ DTS:X           │ DTS:X     │ #444444 (Charcoal Grey)        │
└─────────────────┴───────────┴────────────────────────────────┘
```

---

## 9. Auto-Updater: Sparkle 2 Setup

Sparkle provides secure updates signed with an Ed25519 key.

### Setup in `MovieBoxApp.swift`
```swift
import Sparkle

@main struct MovieBoxApp: App {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        Settings {
            SettingsView(updater: updaterController.updater)
        }
    }
}
```

### Info.plist Configuration
```xml
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/yourname/moviebox/main/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>YOUR_BASE64_ED25519_PUBLIC_KEY</string>
<key>SUEnableAutomaticChecks</key>
<true/>
```

---

## 10. Efficiency Checklist — for the Coding Agent

Revisit on every PR. If any item is violated, fix it before merging.

### Memory
- [ ] `NSCache` with explicit `countLimit` and `totalCostLimit` for poster assets.
- [ ] Torrent pieces: max 2 in RAM at once, rest flushed to disk immediately.
- [ ] `AVPlayerLayer` reused across playback sessions — never recreate from scratch.
- [ ] Poster images sized to display size (use TMDB's `w342` path, not `original`).
- [ ] `LazyVStack` / `LazyHStack` for all scroll views — never `VStack` inside `ScrollView`.

### CPU
- [ ] All network I/O on background actors — never on `@MainActor`.
- [ ] Image decoding on background thread: `DispatchQueue.global().async` or `Task.detached`.
- [ ] ffprobe runs in detached `Task` — never blocks UI.
- [ ] MLRecommender training in `Task.detached(priority: .background)`.
- [ ] `AVAssetImageGenerator` frames extracted lazily — only when scrubber is hovered.

### Network
- [ ] HTTP/2 with connection coalescing for TMDB (single `URLSession` instance).
- [ ] Deduplicate in-flight image requests (custom `ImageLoader` actor).
- [ ] Backend proxy with `cf: { cacheEverything: true }` for stable endpoints.
- [ ] Torrent searches cancelled if user navigates away before results arrive.

### Disk
- [ ] Piece files in `tmp/moviebox-stream/` — auto-cleaned on app quit.
- [ ] SwiftData `ModelContext` never accessed from a background thread directly — use `ModelActor`.

### SwiftUI rendering
- [ ] `@Observable` instead of `ObservableObject` everywhere (Swift 5.9+).
- [ ] No `AnyView` type erasure in hot paths (scroll views, list cells).
- [ ] `.drawingGroup()` on poster card hover shadows to rasterize the composite.
- [ ] `equatable()` on cells that receive frequent updates.

---

## 11. Dependencies Summary

| Dependency | Source | Purpose |
|---|---|---|
| `warppipe/swift-torrent` | SPM | Low-level BitTorrent logic support |
| `apple/swift-nio` | SPM | Base socket and HTTP library for range requests |
| `apple/swift-collections` | SPM | Efficient queues and bitmaps for piece maps |
| `sparkle-project/Sparkle` | SPM | Auto-updater component |
