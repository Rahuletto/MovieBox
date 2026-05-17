# MovieBox TODO

Prioritized backlog of real gaps, cracks, and inefficiencies found in an end-to-end audit.
Items are grouped by severity, then by area. File paths and line numbers are quoted where applicable.

---

## TL;DR

The build passes but masks major functional gaps. The biggest issue: the BitTorrent path is **not actually correct end-to-end** today. Several items marked "done" in [.agents/KT.md](./KT.md) are still stubbed, unwired, or internally inconsistent. Pause new feature work and stabilize streaming correctness, shared app state, and TV-aware persistence first.

### Recommended order

1. **Freeze / feature-flag** the Stream + Download UI until the torrent protocol is fixed. — S
2. **Fix protocol correctness cluster**: magnet metadata acquisition, tracker requests, piece/block assembly, range server. — XL
3. **Make stream/download state app-scoped**, not per-view. One shared `DownloadManager`, one owned current `StreamSession`, explicit teardown. — M
4. **Finish TV-awareness** across model + routing + persistence. Persist `MediaKind`; stop hardcoding `.movie`. — M
5. **Narrow test suite around the broken seams** before more refactors. — M

---

## Critical

### A. CoreStreaming correctness

- [ ] **The "real BitTorrent" pipeline is still effectively stubbed.**
  - [StreamingOrchestrator.swift:30-43](../App/CoreStreaming/Sources/CoreStreaming/StreamingOrchestrator.swift) builds `TorrentMetadata` from a magnet by guessing piece length/count and filling `pieces` with zero bytes.
  - [DownloadManager.swift:113-125](../App/CoreStreaming/Sources/CoreStreaming/DownloadManager.swift) does the same with a hardcoded 1 GB total size.
  - `TorrentFileParser` exists ([TorrentMetadata.swift:136-299](../App/CoreStreaming/Sources/CoreStreaming/TorrentMetadata.swift)) but is unused — there is no real magnet metadata exchange wired in.
  - **Action:** implement real metadata resolution (extension protocol BEP 9 `ut_metadata`, or .torrent file fetch) OR disable Stream/Download for magnet-only sources.

- [ ] **Piece assembly is broken; pieces cannot complete correctly.**
  - [PieceManager.swift:56-73](../App/CoreStreaming/Sources/CoreStreaming/PieceManager.swift) preallocates a full-size buffer and then treats `buffer.count >= pieceSize` as "piece complete", so it tries to verify after the first block.
  - [PeerConnection.swift:404-410](../App/CoreStreaming/Sources/CoreStreaming/PeerConnection.swift) drops the incoming `offset` when invoking `onPieceReceived`.
  - [StreamingOrchestrator.swift:324-329](../App/CoreStreaming/Sources/CoreStreaming/StreamingOrchestrator.swift) always calls `markBlockReceived(... offset: 0 ...)`.
  - **Impact:** multi-block pieces overwrite at offset 0 and fail hash verification.
  - **Action:** pass `(pieceIndex, offset, block)` end-to-end; track received block ranges; verify only when all blocks are present.

- [ ] **Tracker protocol handling is incorrect enough to break peer discovery.**
  - HTTP tracker likely double-encodes `info_hash`: [TrackerClient.swift:31-42](../App/CoreStreaming/Sources/CoreStreaming/TrackerClient.swift) + 148-157 manually percent-encode, then feed into `URLQueryItem` (re-encodes `%`).
  - UDP tracker sends invalid peer ID: [UDPTrackerClient.swift:37-40](../App/CoreStreaming/Sources/CoreStreaming/UDPTrackerClient.swift) runs `hexToData` on `peerId`, but peer IDs are ASCII 20-byte values, not hex strings.
  - UDP tracker caches one `connectionId` globally across trackers ([UDPTrackerClient.swift:7-8, 86-119](../App/CoreStreaming/Sources/CoreStreaming/UDPTrackerClient.swift)); connection IDs are tracker-specific.
  - **Action:** rebuild tracker requests from protocol specs; cache UDP connection IDs per `(host, port)`; add unit tests with known-good packets.

- [ ] **DHT implementation is not functionally correct.**
  - [KademliaDHT.swift](../App/CoreStreaming/Sources/CoreStreaming/KademliaDHT.swift) `findPeers` uses `find_node`, not `get_peers` (96-120, 165-185).
  - `announce_peer` omits the required token (188-193).
  - Response transaction ID is read from `args["t"]` instead of top-level message (221-243).
  - Compact node encoding is wrong; appends ASCII address string instead of 4-byte IP bytes (294-307).
  - Bootstrap nodes are seeded with empty node IDs (317-321).
  - **Action:** treat DHT as nonfunctional today; either remove it from discovery flow or reimplement against BEP 5 properly.

- [ ] **`HTTPRangeServer` is not safe/correct for real playback.**
  - [HTTPRangeServer.swift:94-118](../App/CoreStreaming/Sources/CoreStreaming/HTTPRangeServer.swift) loses partial request data because `buffer` is local to each recursive call.
  - 173-187 builds headers in a way that likely ends with only a single `\r\n`, not a proper blank line.
  - 132-170 reads from `PieceStore` without checking availability; `PieceStore` precreates the backing file with zero-filled bytes ([PieceStore.swift:23-29](../App/CoreStreaming/Sources/CoreStreaming/PieceStore.swift)); availability checks exist (63-69) but are unused.
  - **Impact:** fragmented HTTP requests, malformed responses, and serving unwritten zero-bytes to AVPlayer.
  - **Action:** keep per-connection request buffers, validate ranges, wait for piece availability, stream only from actual available bytes.

### B. App state / lifecycle

- [ ] **Downloads and streaming are owned by the wrong objects.**
  - [RootView.swift:605](../App/MovieBox/RootView.swift) creates a `DownloadManager` inside `TorrentSection`; [RootView.swift:1044](../App/MovieBox/RootView.swift) creates a separate one inside `DownloadsView`.
  - [RootView.swift:15](../App/MovieBox/RootView.swift) keeps one shared `StreamingOrchestrator`, but each row creates its own `StreamSession` against that shared mutable orchestrator (687-699). `MovieDetailView` has an unused `activeStreamSession` (325).
  - **Impact:** a download started from detail will not reliably appear in Downloads; multiple stream attempts can stomp each other's state.
  - **Action:** promote download + current-stream ownership to app scope and inject them via `@Environment`.

- [ ] **Stream sessions are never properly torn down.**
  - `StreamSession.cancel()` exists ([StreamSession.swift:79-84](../App/CoreStreaming/Sources/CoreStreaming/StreamSession.swift)) but is never called from `RootView`/`TorrentResultRow`.
  - Dismissing the player does not stop the orchestrator.
  - **Impact:** leaked tasks, open listeners, temp files, background torrent activity.
  - **Action:** own the current session centrally; cancel on dismiss, route change, and before starting another stream.

---

## High

### C. TV support / persistence integrity

- [ ] **TV support is incomplete in persistence and routing.**
  - [CoreStorage.swift:5-13](../App/CoreStorage/Sources/CoreStorage/CoreStorage.swift) (`MovieRecord`) and 52-64 (`DownloadRecord`) do not store `MediaKind`. Both key by unique `tmdbId`, which is insufficient once movies + TV coexist.
  - UI still hardcodes movie routing in several places:
    - Home continue-watching/watchlist: [RootView.swift:99-105](../App/MovieBox/RootView.swift)
    - My List: [RootView.swift:1281-1284](../App/MovieBox/RootView.swift)
    - Search results: [SearchView.swift:193-199](../App/MovieBox/SearchView.swift)
  - **Action:** persisted IDs at minimum `(tmdbId, mediaKind)`; route all stored items with kind.

- [ ] **Search is currently wrong for mixed movie/TV results.**
  - [SearchView.swift:220-224](../App/MovieBox/SearchView.swift) merges movie + TV results into one `[Movie]` and dedupes only on numeric `id`.
  - 193-199 always routes taps to `.movie`.
  - **Action:** typed result model like `{ kind, movie }`; route with kind.

- [ ] **TMDB TV mapping is incomplete.**
  - [CoreMetadata.swift:275-299](../App/CoreMetadata/Sources/CoreMetadata/CoreMetadata.swift) maps `title/name`, but has no `firstAirDate` — TV rows/details show empty dates.
  - `movieDetail` does not fetch TV-specific extras (184-194).
  - **Action:** split DTOs or add TV fields explicitly (`firstAirDate`, `episodeRunTime`, etc.).

### D. Downloads / SwiftData

- [ ] **Download persistence is mostly not wired.**
  - `DownloadRecord` exists; Downloads UI queries it ([RootView.swift:1043-1063](../App/MovieBox/RootView.swift)) — but no inserts/updates of `DownloadRecord` anywhere in the repo.
  - **Impact:** no persistent download state, no restart recovery, persisted downloads list is effectively dead.
  - **Action:** write `DownloadRecord` on enqueue/progress/complete; hydrate `DownloadManager` from it on launch.

- [ ] **Pause/resume is not real resume.**
  - [DownloadManager.swift:66-80](../App/CoreStreaming/Sources/CoreStreaming/DownloadManager.swift) pauses by stopping the engine; resume just calls `executeDownload` again.
  - [PieceStore.swift:25-29](../App/CoreStreaming/Sources/CoreStreaming/PieceStore.swift) deletes any existing partial file when re-created.
  - **Impact:** resume restarts from scratch and may destroy partial data.
  - **Action:** keep existing `PieceStore`/bitmap state; restart the engine against it instead of recreating storage.

- [ ] **`DownloadRecord` data model is too weak.**
  - [CoreStorage.swift:52-64](../App/CoreStorage/Sources/CoreStorage/CoreStorage.swift) keys downloads uniquely by `tmdbId` only. Cannot represent multiple qualities, releases, or TV episodes.
  - **Action:** key by `(tmdbId, mediaKind, infoHash)` at minimum.

### E. Concurrency / strict Swift 6 risks

- [ ] **Network code pinned to `@MainActor` / `.main` unnecessarily.**
  - [PeerConnection.swift:120](../App/CoreStreaming/Sources/CoreStreaming/PeerConnection.swift), [HTTPRangeServer.swift:6](../App/CoreStreaming/Sources/CoreStreaming/HTTPRangeServer.swift), [KademliaDHT.swift:20](../App/CoreStreaming/Sources/CoreStreaming/KademliaDHT.swift), [StreamingOrchestrator.swift:6](../App/CoreStreaming/Sources/CoreStreaming/StreamingOrchestrator.swift) keep network-heavy logic on the main actor and start `NWConnection`/`NWListener` on `.main`.
  - **Impact:** UI starvation risk and avoidable actor contention.
  - **Action:** move protocol/network state off the main actor; publish UI state back to MainActor only when needed.

- [ ] **Continuation double-resume hazards.**
  - [UDPTrackerClient.swift:129-160](../App/CoreStreaming/Sources/CoreStreaming/UDPTrackerClient.swift) can resume on receive/failure and then again from the 15s timeout closure.
  - [PeerConnection.swift:193-206](../App/CoreStreaming/Sources/CoreStreaming/PeerConnection.swift) swaps handlers and can resume the checked continuation on `.ready`, then later again on `.failed`.
  - **Impact:** potential crashes under load or slow networks.
  - **Action:** guard continuation completion with a single atomic/actor-owned state.

### F. Persistence / error handling

- [ ] **Watch history saves every 0.5s, not every 5s — and errors are swallowed.**
  - [CorePlayer.swift:175-184](../App/CorePlayer/Sources/CorePlayer/CorePlayer.swift) installs a periodic observer at 0.5 s.
  - [RootView.swift:35-39, 66-72](../App/MovieBox/RootView.swift) saves SwiftData via `try? modelContext.save()` on every callback.
  - **Action:** throttle to 5–10 s or meaningful deltas; surface save failures.

- [ ] **User-facing failures are often silent or generic.**
  - `try? modelContext.save()` in several places: [RootView.swift:71, 442, 454, 473, 1322](../App/MovieBox/RootView.swift), [SettingsView.swift:67](../App/MovieBox/SettingsView.swift).
  - Torrent search failures are just `NSLog`: [CoreTorrent.swift:206-219](../App/CoreTorrent/Sources/CoreTorrent/CoreTorrent.swift).
  - Subtitle load failure is just `NSLog`: [CorePlayer.swift:72-74](../App/CorePlayer/Sources/CorePlayer/CorePlayer.swift).
  - **Action:** one reusable app error presenter / toast / inline state for these flows.

- [ ] **`PlayerState.dismiss()` does not fully clean subtitle state.**
  - [CorePlayer.swift:59-75](../App/CorePlayer/Sources/CorePlayer/CorePlayer.swift) starts `subtitleLoadTask`; 111-119 dismisses without canceling it or clearing `subtitleStream`, `currentSubtitleText`, `activeSubtitleTrack`.
  - **Action:** cancel and nil the subtitle task/stream on dismiss and on new load.

### G. Feature plumbing gaps / KT mismatches

- [ ] **Jackett is implemented but not wired into the app.**
  - `TorrentSearchAggregator.configureJackett(...)` exists ([CoreTorrent.swift:196-199](../App/CoreTorrent/Sources/CoreTorrent/CoreTorrent.swift)); Settings expose Jackett fields ([SettingsView.swift:203-237](../App/MovieBox/SettingsView.swift)); but detail search uses a fresh default aggregator with no config: [RootView.swift:421-424](../App/MovieBox/RootView.swift).
  - **Action:** build the aggregator from `AppSettings`.

- [ ] **TV torrent search is effectively broken.**
  - TV detail uses the same `TorrentSearchAggregator().search(movieTitle:)` path ([RootView.swift:417-425](../App/MovieBox/RootView.swift)) even though YTS is movie-only ([CoreTorrent.swift:248-277](../App/CoreTorrent/Sources/CoreTorrent/CoreTorrent.swift)).
  - **Action:** hide torrent search for TV until Jackett is actually wired, or add a TV-capable source.

---

## Medium

### H. Metadata / backend / unfinished features

- [ ] **Trailer playback UI exists, but metadata never populates `trailerURL`.**
  - `MovieDetail.trailerURL` declared ([CoreMetadata.swift:68-82](../App/CoreMetadata/Sources/CoreMetadata/CoreMetadata.swift)); UI checks it ([RootView.swift:345, 557-560](../App/MovieBox/RootView.swift)); but `MetadataClient.movieDetail` only fetches detail/credits/similar (184-194) — never `/videos`.
  - **Action:** fetch `/videos` and map YouTube/Vimeo trailer URLs.

- [ ] **OMDb is configured in models/settings, but unused.**
  - `MetadataEndpointMode.direct` carries `omdbAPIKey` ([CoreMetadata.swift:85-88](../App/CoreMetadata/Sources/CoreMetadata/CoreMetadata.swift)); Settings persists it; backend exposes `/api/omdb`; app never calls OMDb.
  - **Action:** either remove OMDb from the "done" story or actually enrich details with it.

- [ ] **`RemuxService` is unused and partly wrong.**
  - No call sites in repo. `detectHDR` uses ffprobe-style flags with the ffmpeg binary ([RemuxService.swift:51-67](../App/CoreStreaming/Sources/CoreStreaming/RemuxService.swift)).
  - **Action:** wire real `ffprobe` usage or remove the claim.

- [ ] **Backend subtitle download is an open fetcher.**
  - [Backend/src/index.ts:277-307](../Backend/src/index.ts) accepts arbitrary `url` and fetches if it starts with `http`. SSRF / open-proxy risk.
  - **Action:** whitelist allowed hostnames (e.g., `subf2m.co` and expected download hosts).

- [ ] **Backend rate limiting is race-prone and headers may be lost.**
  - [Backend/src/index.ts:58-83](../Backend/src/index.ts) does KV `get` then `put` (non-atomic) and sets headers on `c.res` before `await next()`.
  - **Action:** set headers after `next()`; use a more atomic limiter if real enforcement is needed.

- [ ] **Backend subtitle search ignores its own parameters.**
  - [Backend/src/index.ts:224-241](../Backend/src/index.ts) accepts `imdb_id` and `type`, but search uses only `title || ''`.
  - **Action:** either use `imdb_id`/`type` or simplify the API.

- [ ] **Network clients lack robust timeouts / retries / cancellation.**
  - `YTSClient.search` uses `session.data(from:)` with no explicit timeout/status handling ([CoreTorrent.swift:248-253](../App/CoreTorrent/Sources/CoreTorrent/CoreTorrent.swift)).
  - Backend TMDB/OMDb fetches have no abort timeout ([Backend/src/index.ts:136-142, 202-204](../Backend/src/index.ts)).
  - Tracker/peer flows have no retry/backoff strategy.
  - **Action:** one shared networking policy instead of ad-hoc requests.

### I. Tests

- [ ] **Coverage is far below risk surface.**
  Current tests: `CoreStreamingTests` (only `PieceStore`), `CoreTorrentTests/ReleaseParserTests`, `CoreMLEngineTests/GenreAffinityEngineTests`, `Backend/src/index.test.ts`.

  Missing tests for:
  - Bencode parsing/encoding
  - Magnet parsing
  - HTTP/UDP tracker packet building & parsing
  - DHT behavior
  - Peer wire parsing / piece assembly
  - Range server request parsing
  - TV search/detail routing
  - SwiftData persistence + migration
  - Download persistence / resume

  Backend CORS test hits `/health` ([Backend/src/index.test.ts:129-133](../Backend/src/index.test.ts)) even though CORS middleware is mounted only on `/api/*`.
  - **Action:** add a small protocol-focused suite before continuing refactors.

---

## Low

### J. Structural / maintainability

- [ ] **`RootView.swift` is too much in one place.**
  - [RootView.swift](../App/MovieBox/RootView.swift) is 1452 lines holding root routing, home/catalog/detail/downloads/library, player launching, subtitle download, torrent search, and SwiftData mutations.
  - **Action:** split by screen; move non-view logic out of views.

- [ ] **Several settings are UI-only / no-op.**
  - Appearance controls use `.constant(...)` in [SettingsView.swift:413-429](../App/MovieBox/SettingsView.swift).
  - Many `AppSettings` fields aren't consumed: `enableYTS`, `enableJackett`, `requestTimeout`, `posterSize`, `backdropSize`, `useHTTPProxy`, etc.
  - **Action:** hide or disable until wired.

- [ ] **`ImageLoader.shared()` uses `nonisolated(unsafe)` singleton state.**
  - [CoreMetadata.swift:235-243](../App/CoreMetadata/Sources/CoreMetadata/CoreMetadata.swift). Swift 6 concurrency footgun.
  - **Action:** replace with an actor-isolated static or DI-managed singleton.

---

## Risks & guardrails

- Do not keep shipping Stream / Download as if production-ready.
- Avoid piecemeal fixes to just one tracker or one view; the torrent path has multiple coupled failures.
- Keep the next pass narrow: **correctness + ownership + persistence + TV-awareness**.
- Add tests before more UI rewrites, or you'll keep rediscovering the same protocol bugs.

## Optional alternative path

If you want a reliable product fastest:

- Disable BitTorrent streaming entirely for now.
- Keep metadata/search/library/player UX.
- Use direct HTTP / local-file playback only until the torrent engine is rebuilt properly.

Less ambitious, but far lower risk than polishing around the current streaming core.
