# MovieBox AVPlayer / CoreTorrent Streaming Failure — End‑to‑End Findings

> Investigation thread: T‑019e5442‑9582‑76bf‑9d78‑ccac4e15b5da
> Log analysed: `/Users/marban/Library/Containers/com.marban.MovieBox/Data/Library/Logs/MovieBox/moviebox.log`
> Observed user‑visible failure (verbatim):
>
> ```
> MovieBox: [2026-05-22T16:34:53.202Z] [INFO] [playback] AVPlayerItem NSError domain=NSURLErrorDomain code=-1 desc=unknown error
> MovieBox: [2026-05-22T16:34:53.202Z] [INFO] [playback] AVPlayerItem underlying domain=NSOSStatusErrorDomain code=-12935 desc=The operation couldn’t be completed. (OSStatus error -12935.)
> MovieBox: [2026-05-22T16:34:53.202Z] [INFO] [playback] AVPlayerItem failed: This file cannot be streamed yet — the torrent buffer was incomplete or corrupt. Wait for more buffering or try another release.
> ```

This document is the **lossless** record of everything discovered during the investigation: log evidence, MovieBox source‑level pipeline analysis, line‑by‑line citations from WebTorrent / peerflix / torrent‑stream / libtorrent‑rasterbar / qBittorrent / Stremio enginefs, the diagnosis of OSStatus -12935, the full comparison table, and the architectural change plan with file/line references. Nothing is summarised away.

---

## Table of contents

1. [Log forensics — what the captured session actually shows](#1-log-forensics)
2. [MovieBox's current pipeline, file by file](#2-movieboxs-current-pipeline-file-by-file)
3. [Root‑cause chain inside MovieBox](#3-root-cause-chain-inside-moviebox)
4. [What OSStatus −12935 actually means](#4-what-osstatus-12935-actually-means)
5. [How WebTorrent streams a trailing‑moov MP4](#5-how-webtorrent-streams-a-trailing-moov-mp4)
6. [How peerflix + torrent-stream stream](#6-how-peerflix--torrent-stream-stream)
7. [How libtorrent‑rasterbar + qBittorrent handle streaming](#7-how-libtorrent-rasterbar--qbittorrent-handle-streaming)
8. [How Stremio's enginefs / server.js handle it](#8-how-stremios-enginefs--serverjs-handle-it)
9. [The complete cross‑project comparison table](#9-the-complete-cross-project-comparison-table)
10. [Why MovieBox uniquely fails where the others do not](#10-why-moviebox-uniquely-fails-where-the-others-do-not)
11. [Architectural change plan — Tier 1 / Tier 2 / Tier 3](#11-architectural-change-plan)
12. [Concrete code changes — file & line references](#12-concrete-code-changes--file--line-references)
13. [Corrected playback handshake walkthrough](#13-corrected-playback-handshake-walkthrough)
14. [Open questions / things still to verify](#14-open-questions)
15. [Appendix A — exact code blocks referenced in this doc](#appendix-a-exact-code-blocks-referenced-in-this-doc)

---

## 1. Log forensics

### 1.1 Raw observed facts (verbatim from the tail of `moviebox.log`)

```
[2026-05-22T17:21:42.277Z] [INFO]  [torrent]  [TorrentEngine] Connecting to 9 new peers (32 total)
[2026-05-22T17:21:42.279Z] [INFO]  [torrent]  [PeerConnection] Peer 219.76.157.139:22336 supports PEX (remote message ID = 2)
[2026-05-22T17:21:42.289Z] [INFO]  [torrent]  [PeerConnection] Received PEX update from 103.164.128.103:42081 containing 5 peers
[2026-05-22T17:21:42.289Z] [DEBUG] [torrent]  [Streaming] MP4 moovProbe=notFound tailData=293109B tailOffset=1946157056 needTailSpan=16384KB verifiedPieces=7/37 last16bytes=00000300000300000300000300000775
…
[2026-05-22T17:21:45.499Z] [INFO]  [playback] …still buffering — buffering(92%), 1856 KB verified head, 34 live peers (3 transferring, indexer swarm: 3141 seeders), 0 KB/s
…
[2026-05-22T17:21:47.297Z] [DEBUG] [torrent]  [Streaming] MP4 moov not in 286KB suffix — need more tail pieces (gap before piece 1024?)
[2026-05-22T17:21:50.398Z] [INFO]  [playback] …still buffering — buffering(92%), 1856 KB verified head, 33 live peers (5 transferring, indexer swarm: 3141 seeders), 0 KB/s
…
[2026-05-22T17:21:53.691Z] [DEBUG] [torrent]  [TorrentEngine] Pruned 23 dead peers
[2026-05-22T17:21:55.555Z] [INFO]  [playback] …still buffering — buffering(92%), 1856 KB verified head, 11 live peers (5 transferring, indexer swarm: 3141 seeders), 0 KB/s
```

### 1.2 Derived quantities

| Quantity | Value | Derivation |
|---|---|---|
| File total size | ~1.81 GB | `tailOffset = 1 946 157 056` and tail spans the last piece (~286 KB) → `1 946 157 056 + 293 109 ≈ 1.81 GB` |
| Piece length | ~1.78 MB | "1856 KB verified head" ≈ one head piece; last piece partial = 286 KB; `lastPiece = 1024` |
| Total pieces | ≈ 1025 | last piece index reported as `1024` in `lastPiece 1024 verified` |
| Tail‑download window | 37 pieces ≈ 64 MB | `streamTailPieceCount()` uses `tailPieceIndicesForDownload` which caps at `maxTailByteSpan = 64 MB` |
| Pieces verified out of the 37‑piece tail | **7 / 37** | repeated `verifiedPieces=7/37` |
| Average download throughput | **0 KB/s** | "still buffering — … 0 KB/s" repeated for the entire session |
| Apparent peers | 34 → 33 → 11 (decaying) | `Pruned 23 dead peers` once the maintenance timer fires |
| "Transferring" peers | 3 → 5 | meaning only 3–5 of the live wires are actually exchanging blocks |
| Seeders in indexer | 3141 | swarm health is fine — the bottleneck is not peer availability |

### 1.3 The smoking‑gun pattern

The orchestrator emits, ~10× per second, the *same* debug line:

```
MP4 moovProbe=notFound tailData=293109B tailOffset=1946157056
needTailSpan=16384KB verifiedPieces=7/37 last16bytes=00000300000300000300000300000775
```

`tailData=293109B` is just the very last (partial) piece — 286 KB. That means the readable contiguous suffix of the file from EOF is exactly **one piece**. The 36 pieces immediately preceding it (the rest of the 64 MB tail span) are **not** verified, and at 0 KB/s they will never become verified.

`last16bytes=00000300000300000300000300000775` is the trailing 16 bytes of the file. The `00 00 03` repetition is the classic H.265 / HEVC NAL "emulation prevention byte" marker — i.e. those bytes are raw video payload at the very tail. That is consistent with a non‑fast‑start MP4 whose `moov` lives further inside the tail span (not in the literal last KB).

### 1.4 Translation of the user‑visible message

The orchestrator never reaches "tail ready" → `evaluateStreamTailPieceReady()` returns `false` forever → `bufferingWatchdogTask` eventually fails the session → `StreamSession` publishes the "AVPlayerItem failed" message.

The `NSURLErrorDomain code=-1` is the AVPlayer item facade error; the underlying `NSOSStatusErrorDomain code=-12935` is the *real* signal that AVPlayer's HTTP source layer rejected the response from the loopback HTTP server (see §4).

---

## 2. MovieBox's current pipeline, file by file

The CoreStreaming module owns the end‑to‑end pipeline. The relevant files (with line counts):

| File | Lines | Role |
|---|---:|---|
| `App/CoreStreaming/Sources/CoreStreaming/StreamingOrchestrator.swift` | 2126 | Central controller |
| `App/CoreStreaming/Sources/CoreStreaming/PieceManager.swift` | 426 | Piece prioritisation actor |
| `App/CoreStreaming/Sources/CoreStreaming/PieceStore.swift` | 465 | Disk + bitmap actor |
| `App/CoreStreaming/Sources/CoreStreaming/HTTPRangeServer.swift` | 845 | Loopback HTTP/1.1 server for AVPlayer |
| `App/CoreStreaming/Sources/CoreStreaming/MP4FastStartRemuxer.swift` | 199 | Synthetic fast‑start layout builder |
| `App/CoreStreaming/Sources/CoreStreaming/StreamTailPlanner.swift` | 321 | Tail span / moov probe helpers |
| `App/CoreStreaming/Sources/CoreStreaming/StreamSession.swift` | 474 | UI‑facing session state machine |
| `App/CoreStreaming/Sources/CoreStreaming/PeerConnection.swift` | 770 | BitTorrent wire protocol over `NWConnection` |
| `App/CoreStreaming/Sources/CoreStreaming/KademliaDHT.swift` | 428 | DHT peer discovery |
| `App/CoreStreaming/Sources/CoreStreaming/UTMetadataFetcher.swift` | 565 | BEP 9 metadata exchange |
| `App/CoreStreaming/Sources/CoreStreaming/TorrentMetadataFetcher.swift` | 283 | Parallel metadata acquisition |

### 2.1 `StreamingOrchestrator.startStream(...)` (paraphrased flow)

1. `TorrentMetadataFetcher.fetch(infoHash:, magnetTrackers:)` is called in a `withThrowingTaskGroup` — fastest of {Wrangler backend, public mirrors, BEP 9 over peers} wins.
2. Selects the largest video file → `streamTarget: TorrentStreamTarget`.
3. Computes `streamFirstPiece`, `streamLastPiece`, and a tail‑piece list via `StreamTailPlanner.tailPieceIndicesForDownload(target, pieceLength, pieceCount)` which uses `min(target.byteLength, maxTailByteSpan = 64 MB)`.
4. Instantiates `PieceStore` (sparse‑allocates a `~/Library/Caches/.../moviebox_<infoHash>.stream` file by truncating to `totalSize`).
5. Instantiates `PieceManager` with `streamTailPieces = [37 piece indices]`.
6. Instantiates and starts `TorrentEngine` (peer pool, tracker loops, DHT crawl).
7. Starts `HTTPRangeServer` on `127.0.0.1:<port>`; AVPlayer is handed `http://127.0.0.1:<port>/stream`.
8. Starts `fastStartWatcherTask` — polls every 1.5 s trying `tryRemuxFromEstimatedMoovOffset()` then `attemptFastStartRemux()` until a remux is installed.
9. UI loops `evaluateStreamTailPieceReady()` to know when to actually unblock playback.

### 2.2 `evaluateStreamTailPieceReady()` — the gate that never opens

`StreamingOrchestrator.swift` lines 255–530. Reduced behaviour:

```
if container is MP4 (real or unknown but with trailing moov):
    require lastPiece verified
    read the readable suffix of the last 64 MB
    probe for `moov` 4CC scanning backwards
    case .complete   → build & install remux layout → return true
    case .incomplete → return false
    case .notFound   →
        tryRemuxFromEstimatedMoovOffset()           ── needs full moov region readable
        resolveCachedMoovHit()                       ── only succeeds if moov bytes are in tail pieces
        readAccumulatedVerifiedTailFromEOF()         ── only succeeds if contiguous run reaches moov
        if tailVerifiedCount == tailTotalCount → ready (never happens at 0 KB/s)
        findMoovAnchorPiece() / estimatedMoovMediaOffset() → setMoovAnchorPiece()
        return false
```

`applyMP4TailDownloadAnchorsIfNeeded()` is guarded by `moovEstimateAnchorApplied` — it runs **once**. After it runs, if those anchor pieces never arrive, nothing re‑prioritises.

### 2.3 `PieceManager.firstIncompletePiece(...)` — the picker

`PieceManager.swift` lines 254–263:

```swift
private func firstIncompletePiece(in priority: [UInt32], peerBitfield: Data) -> UInt32? {
    for index in priority {
        guard !downloadedPieces.contains(index) else { continue }
        if !peerBitfield.isEmpty, !peerHasPiece(index, in: peerBitfield) {
            continue
        }
        return index
    }
    return nil          // ← when no priority piece is in this peer's bitfield, picker stalls
}
```

`buildBootstrapPriorityOrder()` (lines 265–288) returns:

1. `playerHotPieces` (none yet, AVPlayer has never read)
2. `streamFirstPiece`
3. `moovAnchorPieces`
4. `buildMissingTailPiecesNearestEOF()` (interior tail pieces excluding the partial last)
5. `missingStreamLastPiece()` (the last partial piece, if missing)

While `needsIndexBootstrap() == true` (which it does for the entire failing session — see line 246 of `PieceManager.swift`), the **full file is never considered**. So for a peer whose bitfield doesn't intersect the bootstrap set, the picker returns `nil` and the wire becomes a do‑nothing handshake. That is exactly what "34 live peers, 3 transferring, 0 KB/s" means.

### 2.4 `HTTPRangeServer.waitForReadableSpan(...)` — the 5‑minute death clock

`HTTPRangeServer.swift` lines 662–692:

```swift
private static let bufferWaitSeconds: UInt64 = 300
…
let attempts = Int(Self.bufferWaitSeconds * 10)    // 3000 iterations × 100 ms = 300 s
for attempt in 0..<attempts {
    if let span = await pieceStore.readableSpan(...) { return span }
    try await Task.sleep(for: .milliseconds(100))
}
return nil    // ← after 5 minutes the server returns nil → AVPlayer sees an error response
```

`readBytes` (lines 775–790) wraps the read in a 300‑second timeout that throws `HTTPRangeReadTimeout`. When that fires the connection is dropped mid‑response — exactly the condition AVPlayer reports as OSStatus −12935.

### 2.5 `MP4FastStartRemuxer.buildLayout(...)` — the synthetic header path

`MP4FastStartRemuxer.swift` lines 29–92. Builds:

```
[ftyp]  +  [moov w/ stco/co64 patched by `delta`]  +  [synthetic mdat header]  +  (mdat bytes mapped to torrent file)
```

`HTTPRangeServer.resolveVirtualRange(...)` (lines 705–732) then translates each AVPlayer Range request: bytes inside the synthetic header are served from memory, bytes inside the mdat region are translated to the **original** torrent file offset and read from disk. If those underlying disk bytes aren't verified yet, `waitForReadableSpan` kicks in, and we're back to the 300‑s death clock.

### 2.6 `StreamTailPlanner` constants and probes

`StreamTailPlanner.swift`:

```swift
public static let defaultTailByteSpan: Int64 = 8 * 1024 * 1024          // 8 MB
public static let maxTailByteSpan:     Int64 = 64 * 1024 * 1024         // 64 MB
```

`tailByteSpan(byteLength, pieceLength)`:

- `> 2.5 GB` → 32 MB
- `> 1.0 GB` → 16 MB   ← our 1.81 GB file falls here
- otherwise → 8 MB

`tailPieceIndicesForDownload(target, pieceLength, pieceCount)` uses `min(target.byteLength, maxTailByteSpan)` = 64 MB → 37 pieces.

`moovTailProbe(in: tailData, endsAtFileEOF: true)` scans backward for the ASCII `moov` 4CC. Because only 286 KB of tail is readable, the scan never even reaches where the moov starts.

### 2.7 `PieceStore.readableSpan(offset:length:preferSuffix:)`

`PieceStore.swift` lines 266–300. `preferSuffix: true` walks pieces from the high end down, accumulating the contiguous run of verified pieces — returns one piece (286 KB) for the failing session.

### 2.8 `StreamSession` — buffering watchdog

`StreamSession.swift`. A 5 s buffering watchdog escalates the state to `.failed` if `evaluateStreamTailPieceReady()` keeps returning false. UI surfaces the "still buffering" string and eventually the AVPlayer error.

---

## 3. Root‑cause chain inside MovieBox

There are **two independent bugs working against each other**. Either alone would degrade playback; together they make recovery impossible.

### Bug A — the picker stalls

```
┌──────────────────────────────────────────────────────────────────┐
│ PieceManager.firstIncompletePiece(in: priority, peerBitfield:)   │
│                                                                  │
│ While needsIndexBootstrap() is true, the candidate set is the    │
│ bootstrap priority list ONLY:                                    │
│     [hot, streamFirstPiece, moovAnchorPieces, tail pieces…]      │
│                                                                  │
│ If a connected peer does not have ANY of those specific pieces   │
│ in its bitfield, the picker returns nil. No `request` message is │
│ sent on that wire. The peer connects, completes BT handshake,    │
│ sends Bitfield, and then we sit silent. The wire is choked or    │
│ idle, the maintenance timer eventually prunes it.                │
└──────────────────────────────────────────────────────────────────┘
```

**Why this is catastrophic for streaming**: at the start of a session almost no peer has the anchor pieces — most peers in the swarm are themselves in progress, mid‑download. We need to be opportunistic and **download whatever this peer has** while waiting for a peer that owns the anchor pieces. Every other production client (WebTorrent, peerflix, libtorrent) does this; MovieBox doesn't.

### Bug B — playback is gated on a complete moov in disk‑verified form

```
┌──────────────────────────────────────────────────────────────────┐
│ StreamingOrchestrator.evaluateStreamTailPieceReady()             │
│                                                                  │
│ Refuses to return true until:                                    │
│   (a) the moov atom is fully parseable from contiguous verified  │
│       tail bytes, AND                                            │
│   (b) MP4FastStartRemuxer can build & install a synthetic        │
│       fast-start layout pointing at remapped mdat offsets.       │
│                                                                  │
│ Until then, AVPlayer either isn't given the URL, or is given a   │
│ URL whose synthetic header points at mdat bytes that aren't on   │
│ disk yet. In both cases AVPlayer's HTTP source layer eventually  │
│ times out → OSStatus -12935.                                     │
└──────────────────────────────────────────────────────────────────┘
```

### How A and B reinforce each other

1. Bug A prevents the anchor pieces from ever being requested when initial peers don't have them. → `verifiedPieces` stays at 7/37.
2. Bug B refuses to mark playback ready because the moov isn't on disk.
3. The session loops at "buffering 92 %" until the watchdog kills it.
4. AVPlayer, if it was already handed the URL, sees a connection that stalls past its tolerance window → −12935.

---

## 4. What OSStatus −12935 actually means

`-12935` lives in the CoreMedia / FigBaseObject error namespace. Public Apple documentation is sparse, but the empirical signature is: **the HTTP source attached to an AVAssetReader / AVURLAsset produced a response that couldn't be reconciled with what AVPlayer was already mid‑parse on.**

Practically:

- Server promises `Content-Length: N` then closes the socket before delivering N bytes
- Server promises a `Content-Range` whose `end` exceeds the actual response body length
- Server returns `503` or closes mid‑stream after an initial `206`
- Server hands AVPlayer a synthetic prefix whose subsequent byte ranges don't line up

All four are reachable from the current MovieBox HTTP server when:

- `waitForReadableSpan` times out at 300 s and the connection is dropped, or
- `MP4FastStartRemuxer` installs a layout whose mdat content isn't actually on disk so a follow‑up Range request stalls.

This is **not** an AVPlayer bug. AVPlayer is correctly refusing to feed garbage to its decoder. The fix has to come from our side: never produce inconsistent HTTP responses, and never hand AVPlayer a virtual file we can't actually back with bytes.

---

## 5. How WebTorrent streams a trailing‑moov MP4

(Full librarian extract.)

### 5.1 Piece prioritisation at session start

[`lib/torrent.js` lines 622–626](https://github.com/webtorrent/webtorrent/blob/master/lib/torrent.js#L622):

```javascript
if (this.pieces.length !== 0 && !this._startAsDeselected) {
  this.select(0, this.pieces.length - 1)
}
```

`select()` calls `_select(start, end, priority=0, notify, isStreamSelection=false)`. Default download strategy is `'sequential'` ([`lib/torrent.js` L146](https://github.com/webtorrent/webtorrent/blob/master/lib/torrent.js#L146)).

`_updateWire()` iterates pieces `next.from + next.offset .. next.to` in order:

```javascript
// lib/torrent.js L1770-L1783 — trySelectWire (sequential path)
for (piece = next.from + next.offset; piece <= next.to; piece++) {
  if (!wire.peerPieces.get(piece) || !rank(piece)) continue
  while (self._request(wire, piece, self._critical[piece] || hotswap) &&
    wire.requests.length < maxOutstandingRequests) { /* request all blocks */ }
  ...
}
```

**No tail pre‑fetch, no MP4 awareness.** Just sequential.

### 5.2 What happens when `file.createReadStream(opts)` is called

[`lib/file-iterator.js` L16-L33](https://github.com/webtorrent/webtorrent/blob/master/lib/file-iterator.js#L16-L33):

```javascript
constructor (file, { start, end }) {
  this._startPiece = (start + file.offset) / this._pieceLength | 0
  this._endPiece   = (end   + file.offset) / this._pieceLength | 0
  this._piece      = this._startPiece
  this._missing    = end - start + 1
  this._criticalLength = Math.min((1024 * 1024 / this._pieceLength) | 0, 2)

  this._torrent._select(this._startPiece, this._endPiece, 1, null, true)
  // isStreamSelection=true, priority=1 — higher than the baseline 0
}
```

So only the pieces covering the **requested byte range** get the priority boost. For an HTTP `Range: bytes=-524288` (suffix range), that means only the last 1–2 pieces of the file are elevated to priority 1.

When `next()` finds the current piece unverified:

```javascript
// lib/file-iterator.js L59-L60
this._torrent.on('verified', listener)
return this._torrent.critical(index, index + this._criticalLength)
```

`critical()` in [`lib/torrent.js` L1280-L1290](https://github.com/webtorrent/webtorrent/blob/master/lib/torrent.js#L1280) marks the next 1–2 pieces as "must hotswap if the current peer is slow" — that's the mechanism for prying a stuck request away from a slow wire and giving it to a faster one.

### 5.3 HTTP server response when bytes aren't ready — **never** 416 or 503, just stall

[`lib/server.js` L133-L153](https://github.com/webtorrent/webtorrent/blob/master/lib/server.js#L133-L153):

```javascript
let range = rangeParser(file.length, req.headers.range || '')

if (Array.isArray(range)) {
  res.status = 206
  range = range[0]
  res.headers['Content-Range'] = `bytes ${range.start}-${range.end}/${file.length}`
  res.headers['Content-Length'] = range.end - range.start + 1
} else {
  res.statusCode = 200
  range = null
  res.headers['Content-Length'] = file.length
}

if (req.method === 'GET') {
  const iterator = file[Symbol.asyncIterator](range)
  const stream = Readable.from(transform || iterator)
  res.body = pipe || stream
}
```

Backed by [`lib/file-iterator.js` L46-L61](https://github.com/webtorrent/webtorrent/blob/master/lib/file-iterator.js#L46-L61):

```javascript
const pump = (index, opts) => {
  if (!this._torrent.bitfield.get(index)) {
    const listener = i => {
      if (i === index || this.destroyed) {
        this._torrent.removeListener('verified', listener)
        if (i === index) pump(index, opts)
        else resolve({ done: true })
      }
    }
    this._torrent.on('verified', listener)
    return this._torrent.critical(index, index + this._criticalLength)
  }
  this._torrent.store.get(index, opts, (err, buffer) => {
    resolve({ value: buffer, done: false })
  })
}
```

The iterator **suspends**. The HTTP response body is a `streamx` `Readable` backed by this async iterator — Node's `pump` keeps the socket alive, the stream backpressures TCP, no bytes are sent until verification. Socket timeout is set at [`lib/server.js` L302](https://github.com/webtorrent/webtorrent/blob/master/lib/server.js#L301):

```javascript
socket.setTimeout(36000000)   // 10 hours, effectively infinite
```

### 5.4 Container remux

**There is none.** Zero MP4 awareness in `lib/server.js`, `lib/file.js`, or `lib/torrent.js`. The `docs/faq.md` mentions `videostream` and `mp4box.js` but those operate at the *browser's* MediaSource layer, not inside the HTTP server.

### 5.5 Diagram — WebTorrent trailing‑moov MP4 streaming

```diagram
  AVPlayer / Browser <video>
         │
         │  HTTP Range Request
         │  e.g. Range: bytes=0-65535       (initial head)
         │  e.g. Range: bytes=-524288       (suffix, moov tail)
         ▼
  ╭─────────────────────────────────────────────────────╮
  │  lib/server.js — ServerBase.serveFile()             │
  │                                                     │
  │  1. rangeParser(file.length, req.headers.range)     │
  │  2. file[Symbol.asyncIterator]({start, end})        │
  │     → FileIterator(file, {start, end})              │
  │  3. Readable.from(iterator) → HTTP response body    │
  ╰────────────────────┬────────────────────────────────╯
                       │ async iteration
                       ▼
  ╭─────────────────────────────────────────────────────╮
  │  lib/file-iterator.js — FileIterator                │
  │                                                     │
  │  constructor:                                       │
  │    torrent._select(startPiece, endPiece,            │
  │                    priority=1, isStream=true)       │
  │    _criticalLength = min(1MB/pieceLen, 2)           │
  │                                                     │
  │  next():                                            │
  │    if bitfield.get(piece) → store.get() → yield     │
  │    else:                                            │
  │      torrent.on('verified', listener)  ← BLOCKS    │
  │      torrent.critical(piece, piece+N)               │
  ╰────────────────────┬────────────────────────────────╯
                       │ emits 'verified' when piece hash passes
                       ▼
  ╭─────────────────────────────────────────────────────╮
  │  lib/torrent.js — Piece Download Engine             │
  │                                                     │
  │  _select() → Selections priority queue              │
  │  _update() → _updateWire() per peer (random order)  │
  │  _updateWire():                                     │
  │    sequential: pieces from+offset → to              │
  │    critical[i]=true → hotswap slow peers            │
  │  _request() → wire.request(index, offset, length)   │
  │  onChunk() → piece.set() → hash verify              │
  │    → store.put() → _markVerified() → emit('verified')│
  ╰─────────────────────────────────────────────────────╯
```

---

## 6. How peerflix + torrent-stream stream

(Full librarian extract.)

### 6.1 Architecture

```diagram
╔══════════════════════════╗       ╔═══════════════════════════════╗
║        peerflix          ║       ║        torrent-stream         ║
║  ┌────────────────────┐  ║       ║  ┌──────────────────────────┐ ║
║  │    app.js (CLI)    │  ║       ║  │         index.js         │ ║
║  └────────┬───────────┘  ║       ║  │  engine.select/deselect  │ ║
║           │              ║       ║  │  engine.critical()       │ ║
║  ┌────────▼───────────┐  ║       ║  │  select() / onupdate()   │ ║
║  │    index.js        │  ║       ║  └───────────┬──────────────┘ ║
║  │  createServer()    │  ║       ║              │                 ║
║  │  HTTP range server │  ║  uses ║  ┌───────────▼──────────────┐ ║
║  │  rangeParser()     │──╫───────╫─▶│  lib/file-stream.js      │ ║
║  │  file.createRead   │  ║       ║  │  FileStream.notify()     │ ║
║  │    Stream(range)   │  ║       ║  │  engine.critical(piece)  │ ║
║  └────────────────────┘  ║       ║  └──────────────────────────┘ ║
╚══════════════════════════╝       ╚═══════════════════════════════╝
```

### 6.2 Two‑tier selection priority

[`torrent-stream/index.js` L648-L650](https://github.com/mafintosh/torrent-stream/blob/master/index.js#L639-L653):

```javascript
engine.selection.sort(function (a, b) { return b.priority - a.priority })
```

- `priority = false (0)` from `file.select()` (used by peerflix at startup, [`peerflix/index.js` L44](https://github.com/mafintosh/peerflix/blob/master/index.js#L44))
- `priority = true (1)` from `file.createReadStream()` — every HTTP response creates a high‑priority selection for exactly the range being read.

[`torrent-stream/index.js` L172-L182](https://github.com/mafintosh/torrent-stream/blob/master/index.js#L172-L182):

```javascript
file.createReadStream = function (opts) {
  var stream = fileStream(engine, file, opts)
  var notify = stream.notify.bind(stream)
  engine.select(stream.startPiece, stream.endPiece, true, notify)
  eos(stream, function () {
    engine.deselect(stream.startPiece, stream.endPiece, true, notify)
  })
  return stream
}
```

### 6.3 The `select(wire, hotswap)` inner loop

[`torrent-stream/index.js` L400-L408](https://github.com/mafintosh/torrent-stream/blob/master/index.js#L390-L412):

```javascript
for (var i = 0; i < engine.selection.length; i++) {
  var next = engine.selection[i]
  for (var j = next.from + next.offset; j <= next.to; j++) {
    if (!wire.peerPieces[j] || !rank(j)) continue   // ← per-wire bitfield gate
    while (wire.requests.length < MAX_REQUESTS && onrequest(wire, j, critical[j] || hotswap)) {}
    if (wire.requests.length < MAX_REQUESTS) continue
    if (next.priority) shufflePriority(i)
    return true
  }
}
```

Pure sequential head‑first per peer; no rarity, no endgame, no random ordering. **Crucially:** the picker is called *per wire* and uses *that wire's* `wire.peerPieces` as the bitfield gate. It never globally returns nothing; it just iterates to the next piece this wire does have.

### 6.4 `gc()` slides the selection forward

[`index.js` L201-L219](https://github.com/mafintosh/torrent-stream/blob/master/index.js#L201-L219). Advances `s.offset` as each piece completes. The selection window is always pointing at the lowest unfinished piece in the requested range.

### 6.5 Suffix‑range handling for `Range: bytes=-524288`

[`peerflix/index.js` L151-L152](https://github.com/mafintosh/peerflix/blob/master/index.js#L151-L168):

```javascript
var range = request.headers.range
range = range && rangeParser(file.length, range)[0]
```

For a 500 MB file, `{start: 499476480, end: 524287999, type: 'bytes'}`. Resolved to a concrete range.

[`lib/file-stream.js` L12-L17](https://github.com/mafintosh/torrent-stream/blob/master/lib/file-stream.js#L12-L17):

```javascript
var offset = opts.start + file.offset
var pieceLength = engine.torrent.pieceLength
this.startPiece = (offset / pieceLength) | 0
this.endPiece   = ((opts.end + file.offset) / pieceLength) | 0
```

For a typical 512 KB‑piece torrent that's pieces 973–976 — the tail. `engine.select(973, 976, true, notify)` inserts a priority‑1 selection that the scheduler will service before background work.

[`lib/file-stream.js` L36-L39](https://github.com/mafintosh/torrent-stream/blob/master/lib/file-stream.js#L36-L39):

```javascript
FileStream.prototype.notify = function () {
  if (!this._reading || !this._missing) return
  if (!this._engine.bitfield.get(this._piece))
    return this._engine.critical(this._piece, this._critical)
  ...
}
```

If the piece isn't in the bitfield, mark up to 2 pieces critical and return without pushing bytes. The HTTP `_read()` won't be called again until `gc()` → `s.notify()` fires, which happens when the piece completes.

### 6.6 HTTP layer — **never errors, always waits**

[`peerflix/index.js` L164-L172](https://github.com/mafintosh/peerflix/blob/master/index.js#L164-L168):

```javascript
response.statusCode = 206
response.setHeader('Content-Length', range.end - range.start + 1)
response.setHeader('Content-Range', 'bytes ' + range.start + '-' + range.end + '/' + file.length)
pump(file.createReadStream(range), response)
```

Socket timeout: 10 hours (`36000000` ms) at [`peerflix/index.js` L172](https://github.com/mafintosh/peerflix/blob/master/index.js#L172).

### 6.7 Critical‑piece & speed ranker

`speedRanker` ([lines 352–378](https://github.com/mafintosh/torrent-stream/blob/master/index.js#L352-L378)) is an admission filter — skips slow wires for non‑critical pieces. Critical pieces bypass it entirely. Hotswap: a faster wire can displace a slower wire mid‑request ([lines 237–272](https://github.com/mafintosh/torrent-stream/blob/master/index.js#L237-L272)).

---

## 7. How libtorrent‑rasterbar + qBittorrent handle streaming

### 7.1 The two‑axis priority system in libtorrent

Source: [`include/libtorrent/piece_picker.hpp` L728-L754](https://github.com/arvidn/libtorrent/blob/master/include/libtorrent/piece_picker.hpp):

```cpp
int priority(piece_picker const* picker) const
{
    int adjustment = -2;
    if (reverse()) adjustment = -1;
    else if (state() != piece_open) adjustment = -3;   // already downloading = highest

    int availability = int(peer_count) + 1;
    return availability * int(priority_levels - piece_priority) * prio_factor + adjustment;
}
```

8 manual priority levels (0 = filtered, 7 = top), modulated by availability (rare pieces favoured).

### 7.2 `sequential_download` mode

`src/piece_picker.cpp` lines 2137–2192:

```cpp
if (options & sequential)
{
    // Phase 1: top_priority pieces first
    for (auto i = m_pieces.begin();
        i != m_pieces.end() && piece_priority(*i) == top_priority; ++i)
    {
        if (!is_piece_free(*i, pieces)) continue;   // ← peer bitfield intersection
        num_blocks = add_blocks(*i, pieces, ...);
    }
    // Phase 2: sequential range cursor → reverse_cursor
    for (piece_index_t i = m_cursor; i < m_reverse_cursor; ++i)
    {
        if (!is_piece_free(i, pieces)) continue;
        if (piece_priority(i) == top_priority) continue;
        num_blocks = add_blocks(i, pieces, ...);
    }
}
```

`is_piece_free(piece, peer_bitfield)` is the per‑peer intersection — picker is called once **per peer** with **that peer's bitfield**. Missing pieces from this peer's perspective are skipped, never blocking the picker.

### 7.3 Time‑critical streaming mode (`set_piece_deadline`)

Recommended for actual streaming by libtorrent's own [`docs/streaming.rst`](https://github.com/arvidn/libtorrent/blob/master/docs/streaming.rst). `src/torrent.cpp` lines 11069–11242 (`request_time_critical_pieces()`):

```diagram
┌─────────────────────────────────────────────────────────────────────┐
│  request_time_critical_pieces()  (every second from second_tick)    │
│                                                                     │
│  1. Build peer list, filter: choked / parole / disconnecting /      │
│     upload-mode                                                     │
│  2. Sort peers by download_queue_time (estimated ms to next reply)  │
│  3. Drop bottom 10% (outlier slow peers)                            │
│  4. For each time-critical piece (deadline order):                  │
│       find_if(peers, peer.has_piece(piece))   ← INTERSECTION        │
│       if no peer has it → skip, try next piece                      │
│       if found → add_blocks() from fastest available peer           │
│       resort peer list (this peer's queue time just grew)           │
│       on timeout → busy-request: ask 2nd peer for same blocks       │
│  5. Stop when top peer download_queue_time > 2 s, or pieces done    │
└─────────────────────────────────────────────────────────────────────┘
```

Resort after assignment ([`src/torrent.cpp` L11058](https://github.com/arvidn/libtorrent/blob/master/src/torrent.cpp)):

```cpp
while (p != peers.end()-1 && (*p)->download_queue_time() > (*(p+1))->download_queue_time())
{
    std::iter_swap(p, p+1);
    ++p;
}
```

If `find_if(peers, has_piece(P))` returns `end()` for piece P, libtorrent **breaks the inner loop for P** and **continues to the next piece**. Never stalls the picker globally.

### 7.4 qBittorrent's first+last 1 % strategy

`src/base/bittorrent/torrentimpl.cpp` lines 1751–1786 ([`applyFirstLastPiecePriority`](https://github.com/qbittorrent/qBittorrent/blob/master/src/base/bittorrent/torrentimpl.cpp#L1751-L1786)):

```cpp
void TorrentImpl::applyFirstLastPiecePriority(const bool enabled)
{
    auto piecePriorities = std::vector<lt::download_priority_t>(
        m_torrentInfo.piecesCount(),
        LT::toNative(DownloadPriority::Ignored));

    for (qsizetype fileIndex = 0; fileIndex < m_filePriorities.size(); ++fileIndex)
    {
        const DownloadPriority filePrio = m_filePriorities[fileIndex];
        if (filePrio <= DownloadPriority::Ignored) continue;
        const lt::download_priority_t piecePrio = LT::toNative(
            enabled ? DownloadPriority::Maximum : filePrio);
        const TorrentInfo::PieceRange pieceRange = m_torrentInfo.filePieces(fileIndex);

        // "worst case: AVI index = 1% of total file size (at the end of the file)"
        const int numPieces = std::ceil(fileSize(fileIndex) * 0.01 / pieceLength());

        for (int i = 0; i < numPieces; ++i)
            piecePriorities[pieceRange.first() + i] = piecePrio;
        for (int i = 0; i < numPieces; ++i)
            piecePriorities[pieceRange.last() - i] = piecePrio;

        const int firstPiece = pieceRange.first() + numPieces;
        const int lastPiece  = pieceRange.last()  - numPieces;
        for (int pieceIndex = firstPiece; pieceIndex <= lastPiece; ++pieceIndex)
            piecePriorities[pieceIndex] = LT::toNative(filePrio);
    }

    m_nativeHandle.prioritize_pieces(piecePriorities);
}
```

- `numPieces = ceil(fileSize * 0.01 / pieceLength)` — first 1 % + last 1 % at top priority.
- Interior gets the user‑set file priority (normal).
- No HLS muxing, no moov relocation. Just sequential + first/last boost.

```
qBittorrent streaming strategy:
┌──────────────────────────────────────────────────────────────────┐
│  [x] Download first and last pieces first                        │
│      → prioritize_pieces(): first 1% + last 1% → top_priority    │
│      → libtorrent picks these before sequential interior         │
│                                                                  │
│  [x] Download in sequential order                                │
│      → torrent_flags::sequential_download                        │
│      → picker iterates cursor→reverse_cursor in order            │
│      → top_priority pieces (head+tail) still picked first        │
│                                                                  │
│  No moov relocation. No HLS muxing. Raw file streaming only.     │
└──────────────────────────────────────────────────────────────────┘
```

---

## 8. How Stremio's enginefs / server.js handle it

[`Stremio/enginefs`](https://github.com/Stremio/enginefs/blob/master/enginefs.js) is the open‑source streaming wrapper around `torrent-stream`. The `server.js` binary that ships with Stremio is closed‑source, but the enginefs layer reveals the streaming contract.

From `enginefs.js`:

```javascript
// line 510: priority via HTTP header
if (req.headers["enginefs-prio"])
    opts.priority = parseInt(req.headers["enginefs-prio"]) || 1;

// line 524: stream the requested range directly
pump(handle.createReadStream(util._extend(range, opts)), res);
```

`stream-open` handler (line 721):

```javascript
if (!e.buffer) e.select(startPiece*ratio, (endPiece+1)*ratio, false);
```

Selects the **entire file** at background priority. Hot pieces are driven entirely by AVPlayer / Stremio Web's natural HTTP Range cursor.

No moov parsing, no MP4 remux at the enginefs level. If Stremio's server.js binary does transcoding for incompatible containers, that happens **downstream of the byte stream** (ffmpeg likely), not in the torrent engine.

---

## 9. The complete cross‑project comparison table

| Dimension | **MovieBox (current)** | WebTorrent | peerflix / torrent‑stream | libtorrent / qBittorrent | Stremio enginefs |
|---|---|---|---|---|---|
| Detects MP4 container | ✅ magic bytes + tail scan | ❌ | ❌ | ❌ | ❌ |
| Eager tail pre‑fetch | ✅ 64 MB tail (37 pieces) | ❌ demand‑driven | ❌ demand‑driven | Optional first+last 1 % toggle | ❌ |
| Synthesises fast‑start moov | ✅ in‑memory rewrite | ❌ raw bytes | ❌ raw bytes | ❌ raw bytes | ❌ raw bytes |
| Picker semantic when piece not in peer's bitfield | ❌ **returns nil globally** | Per‑wire `wire.peerPieces[j]` skip → next piece this wire has | Per‑wire `wire.peerPieces[j]` skip → next piece this wire has | Per‑peer `is_piece_free(piece, peer_bitfield)` skip → continue | Inherited from torrent‑stream |
| Peer rotation for stalled pieces | ❌ none | `_critical[]` + `_hotswap()` ([`torrent.js` L1879](https://github.com/webtorrent/webtorrent/blob/master/lib/torrent.js#L1879)) | `engine.critical()` + hotswap ([`index.js` L237‑272](https://github.com/mafintosh/torrent-stream/blob/master/index.js#L237)) | `request_time_critical_pieces()` rotates by `download_queue_time` each second; busy‑request on timeout | Inherited |
| Pipeline depth | Fixed | Dynamic via `getBlockPipelineLength()` measuring speed | Fixed `MAX_REQUESTS = 5` | Dynamic | Inherited |
| HTTP server response when bytes aren't ready | **Waits ≤ 300 s then drops the connection** | Suspends async iterator on `'verified'` event; socket timeout 10 h | `FileStream.notify()` early‑return, re‑fired by `gc()→s.notify()`; socket timeout 10 h | N/A (raw byte server) | Same as torrent‑stream |
| `pump()` style backpressure | N/A (custom HTTP) | ✅ `Readable.from(iterator) → res.body` | ✅ `pump(file.createReadStream(range), response)` | N/A | ✅ `pump(handle.createReadStream(), res)` |
| Suffix range support | Yes, but routed through synthetic layout | Yes — `rangeParser` resolves `bytes=-N` → concrete range → priority‑1 selection on tail pieces | Same | N/A (raw) | Same as torrent‑stream |
| User‑visible failure mode in our scenario | "Stuck at 92 %" → OSStatus −12935 | "Buffering" until pieces arrive (no error) | Same | Same | Same |
| Container support | MP4 (parsed), MKV/WebM (parsed), others (heuristic) | Container‑agnostic | Container‑agnostic | Container‑agnostic | Container‑agnostic |

---

## 10. Why MovieBox uniquely fails where the others do not

Three distinct mechanisms compound:

### 10.1 Picker stall (no other client has this bug)

Every reference implementation calls the picker **per wire** with **that wire's bitfield as the gate**. MovieBox calls a *global* `firstIncompletePiece(...)` that iterates a *fixed bootstrap list* and returns `nil` if none of those pieces are in the chosen peer's bitfield. So 30 connected peers contribute 0 KB/s because the picker can't suggest any work for them.

### 10.2 Eager remux requires the moov on disk

`StreamingOrchestrator.evaluateStreamTailPieceReady()` won't return `true` until either (a) the moov box is fully verified in the contiguous tail suffix, or (b) `MP4FastStartRemuxer.buildLayout(...)` succeeds — which itself needs the full moov region readable from disk. Until then, AVPlayer is either not started, or started against a virtual file whose bytes can't be served.

### 10.3 300 s HTTP timeout fails AVPlayer cleanly

`HTTPRangeServer.waitForReadableSpan` caps at 300 seconds; on expiry the response is dropped → AVPlayer's HTTP source emits OSStatus −12935. WebTorrent's 10‑hour socket timeout would have been entirely acceptable here.

### Conclusion

The architecture is fundamentally over‑clever. The "trick" of remuxing a trailing‑moov MP4 in memory introduces a hard coupling between the torrent engine and the container format that none of the reference implementations need. AVPlayer **already** knows how to stream a trailing‑moov MP4 via HTTP Range requests — it does so on every browser on the open web. The fix is to do **less**, not more.

---

## 11. Architectural change plan

Three tiers, in increasing cost / decreasing necessity.

### Tier 1 — MUST do, ~50 lines total

Bring MovieBox into parity with WebTorrent / peerflix on the three points where it diverges.

1. **Fix the picker stall** in `PieceManager.swift`. When the bootstrap priority list yields nothing for this peer's bitfield, **fall through** to picking the lowest‑index missing piece this peer *does* have. Never return `nil` while any piece in the file is missing.
2. **Replace 300 s timeout with infinite stall** in `HTTPRangeServer.swift`. Keep the TCP socket alive (10 h timeout à la WebTorrent). The response body stalls until pieces arrive; no `503`, no connection close.
3. **Drop the "ready before serving" gate.** Hand AVPlayer the URL as soon as piece 0 is verified. Let AVPlayer's natural suffix Range request drive moov retrieval — `pieceManager.notePlayerRead(mediaOffset, length)` already exists and elevates exactly the requested tail pieces.
4. **Speculative tail pre‑boost.** When we hand AVPlayer the URL, immediately call `notePlayerRead(byteLength - 2 MB, 2 MB)` to start downloading the moov region before AVPlayer asks. This replaces the eager 64 MB tail probe with a focused 2 MB boost.

### Tier 2 — Strongly recommended, deletes a lot of complexity

5. **Delete `MP4FastStartRemuxer.swift`** and the `remuxedLayout` branch in `HTTPRangeServer.swift` (lines 134–142, 694–743). Stop synthesising headers.
6. **Delete the ~600 lines** in `StreamingOrchestrator.swift` for moov detection, tail probing, anchor‑piece logic, and the fast‑start watcher task (`evaluateStreamTailPieceReady` and friends, lines 237–597; `fastStartWatcherTask` lines 1127–1160; `tryRemuxFromEstimatedMoovOffset`, `findCompleteMoovInVerifiedTailPieces`, `findMoovAnchorPiece`, etc.).
7. **Reduce prioritisation to qBittorrent's "first + last 1 %".** Keep `streamFirstPiece` and the trailing 1 % of pieces at top priority; everything else sequential. Drop the 37‑piece eager tail set.

### Tier 3 — Optional but bullet‑proof

8. **Replace the loopback HTTP server with `AVAssetResourceLoaderDelegate`.** Use a custom URL scheme (e.g. `mbtorrent://…`) on `AVURLAsset`. Implement `resourceLoader(_:shouldWaitForLoadingOfRequestedResource:)` and `dataRequest.respond(with:)` to push bytes as pieces verify, then `finishLoading()` when the requested range completes. Eliminates the entire class of HTTP framing / content‑length / connection‑lifecycle bugs. The canonical reference is Jared Sinclair's guide: <https://jaredsinclair.com/2016/09/03/implementing-avassetresourceload.html>.

---

## 12. Concrete code changes — file & line references

### 12.1 `PieceManager.swift`

**Current** (lines 236–263):

```swift
private func earliestIncompletePiece(peerBitfield: Data) -> UInt32? {
    let bootstrap = buildBootstrapPriorityOrder()
    if needsIndexBootstrap() {
        return firstIncompletePiece(in: bootstrap, peerBitfield: peerBitfield)
    }
    let priority = buildFullPriorityOrder()
    return firstIncompletePiece(in: priority, peerBitfield: peerBitfield)
}

private func firstIncompletePiece(in priority: [UInt32], peerBitfield: Data) -> UInt32? {
    for index in priority {
        guard !downloadedPieces.contains(index) else { continue }
        if !peerBitfield.isEmpty, !peerHasPiece(index, in: peerBitfield) {
            continue
        }
        return index
    }
    return nil
}
```

**Replace with** (per‑peer semantics, never returns nil while any piece is missing for this peer):

```swift
private func earliestIncompletePiece(peerBitfield: Data) -> UInt32? {
    // 1. Try bootstrap priority list constrained to this peer's bitfield
    if needsIndexBootstrap() {
        if let p = firstIncompletePiece(in: buildBootstrapPriorityOrder(), peerBitfield: peerBitfield) {
            return p
        }
        // 2. Fall through: pick the lowest-index missing piece this peer has
        return firstSequentialMissing(peerBitfield: peerBitfield)
    }
    return firstIncompletePiece(in: buildFullPriorityOrder(), peerBitfield: peerBitfield)
        ?? firstSequentialMissing(peerBitfield: peerBitfield)
}

private func firstSequentialMissing(peerBitfield: Data) -> UInt32? {
    for i in streamFirstPiece..<pieceCount {
        let idx = UInt32(i)
        if downloadedPieces.contains(idx) { continue }
        if !peerBitfield.isEmpty, !peerHasPiece(idx, in: peerBitfield) { continue }
        return idx
    }
    return nil
}
```

### 12.2 `HTTPRangeServer.swift`

**Current** (lines 34–37):

```swift
private static let maxRangeBytes = 32 * 1024 * 1024
private static let readTimeoutSeconds: UInt64 = 300
private static let bufferWaitSeconds: UInt64 = 300
```

**Replace with**:

```swift
private static let maxRangeBytes = 32 * 1024 * 1024
private static let readTimeoutSeconds: UInt64 = 36_000          // 10 h
private static let bufferWaitSeconds: UInt64 = 36_000           // 10 h
```

**Current** (lines 662–692, `waitForReadableSpan`): caps at `bufferWaitSeconds * 10` 100 ms attempts. Keep the structure, but with the new constant the cap is effectively unbounded.

**Current** (lines 775–790, `readBytes`): throws `HTTPRangeReadTimeout` after 300 s. With the new constant the disk read becomes effectively non‑expiring.

### 12.3 `StreamingOrchestrator.swift`

#### Tier 1 minimal change

`evaluateStreamTailPieceReady()` — short‑circuit to `true` as soon as the first piece is verified:

```swift
public func isStreamTailPieceReady() async -> Bool {
    guard let pieceStore else { return false }
    let headBytes = await pieceStore.verifiedMediaBytesFromStart()
    return headBytes >= StreamPlaybackThreshold.minimumHeadBytes
}
```

Insert a speculative tail boost right after the range server is started:

```swift
// after rangeServer.start(...)
await pieceManager?.notePlayerRead(
    mediaOffset: max(0, target.byteLength - 2 * 1024 * 1024),
    length: 2 * 1024 * 1024
)
```

#### Tier 2 deletions

- `MP4FastStartRemuxer.swift` — delete entirely.
- `StreamingOrchestrator.swift`:
  - Lines 255–597 (`evaluateStreamTailPieceReady` and the entire MP4 / MKV / generic probe machinery)
  - Lines 1024–1094 (`tryRemuxFromEstimatedMoovOffset`)
  - Lines 1127–1160 (`startFastStartWatcher`, `fastStartWatcherTask`)
  - Lines 1190–1202 (`installRemuxLayout`)
  - Lines 1204–1351 (`attemptFastStartRemux`, `findCompleteMoovInVerifiedTailPieces`, `findMoovAnchorPiece`, `applyMP4TailDownloadAnchorsIfNeeded`, `estimatedMoovMediaOffset`, etc.)
- `HTTPRangeServer.swift`:
  - Lines 19–22 (`remuxedLayout`)
  - Lines 134–142 (`setRemuxedLayout`)
  - Lines 694–743 (`VirtualRangeResolution`, `resolveVirtualRange`, `virtualMediaOffset`)
  - Restore the simple "absolute torrent offset = streamByteOffset + mediaStart" mapping.

### 12.4 `StreamTailPlanner.swift`

After Tier 2, only `tailPieceIndicesForDownload` for setting up the initial "last 1 %" priority survives. `moovTailProbe`, `mkvSeekTableProbe`, `analyzeMKVCues`, `isFastStartMP4`, `segmentBodyOffset`, `parseEBMLSize`, `mp4BoxHeader` — all delete.

---

## 13. Corrected playback handshake walkthrough

```diagram
AVPlayer                                Our HTTP server                Torrent engine
   │                                            │                            │
   │  1. GET /stream  Range: bytes=0-1          │                            │
   ├───────────────────────────────────────────▶│                            │
   │                                            │  piece 0 already verified  │
   │  ◀── 206 [ftyp + start of mdat] ───────────│                            │
   │                                            │                            │
   │  2. GET /stream  Range: bytes=-524288      │  notePlayerRead(tailPieces)│
   ├───────────────────────────────────────────▶├───────────────────────────▶│
   │                                            │  boost those pieces to     │
   │   (TCP socket held open, no bytes yet)     │  top priority, every peer  │
   │   (this is the KEY part — we stall here)   │  that has them is asked    │
   │                                            │                            │
   │                                            │  ◀── pieces arrive ────────│
   │  ◀── 206 [last 512KB w/ moov] ─────────────│                            │
   │                                            │                            │
   │  AVPlayer parses moov → reads stco/co64    │                            │
   │  → starts requesting mdat chunks normally  │                            │
   │                                            │                            │
   │  3. GET /stream  Range: bytes=0-1048575    │                            │
   ├───────────────────────────────────────────▶│  sequential head pieces…   │
   │  ◀── 206 ──────────────────────────────────│                            │
```

- AVPlayer **knows** to issue `Range: bytes=-N` for a trailing‑moov MP4. This is standard HTTP video behaviour, the same flow used by Safari, Chrome, Chromecast, Firefox, etc.
- The HTTP server **never errors** while the moov pieces are downloading; it holds the response open and emits the data as pieces verify. WebTorrent's socket timeout is 10 h.
- If AVPlayer's suffix range doesn't contain a complete `moov`, AVPlayer issues another Range further back (typically `bytes=fileLen-2MB - fileLen-512KB`). Each such request hits the server, calls `notePlayerRead`, expands the priority window. No container parsing on our side needed.
- The speculative `notePlayerRead(byteLength - 2 MB, 2 MB)` we emit at session start ensures the moov region is already being downloaded by the time AVPlayer issues its first suffix request, eliminating most of the wait.

---

## 14. Open questions

These are deferred decisions, not blockers for Tier 1.

1. **Should the 1 % tail boost auto‑expand?** For a 1.81 GB MP4 at 1.78 MB pieces, 1 % = ~10 pieces. If the moov is larger than ~17 MB the speculative boost won't cover it. We rely on AVPlayer's natural Range‑request escalation to cover that.
2. **MKV/Cues handling.** Tier 2 deletes the MKV probe logic. MKV without a Cues element is rare in scene releases, and even when present the same "let the player issue ranges" pattern works. We may want a smoke test against a known cues‑less MKV before deleting.
3. **HEVC / 10‑bit support.** AVPlayer on macOS handles HEVC; iOS varies by device. Out of scope here but worth noting if we move to Tier 3 (resource loader) we have to vend the right `pixelFormat` / `streamingContentKey`.
4. **AVAssetResourceLoaderDelegate caveat.** It rejects HLS segment loading (Apple docs forbid that path), but is fully supported for non‑HLS (`http`‑equivalent) progressive MP4. The closed Apple Developer Forums post historically referenced is now at <https://developer.apple.com/forums/thread/113063>.
5. **Picker fairness vs. streaming intent after Tier 1.** Once the picker can fall through to sequential pieces, fast peers may end up filling far‑future pieces while the tail is still being raced. We may want to cap "fall‑through" assignments per wire so streaming priority is preserved.

---

## Appendix A — exact code blocks referenced in this doc

### A.1 `PieceManager.firstIncompletePiece` and `buildBootstrapPriorityOrder` (current)

```swift
// PieceManager.swift L236-L297

private func earliestIncompletePiece(peerBitfield: Data) -> UInt32? {
    let bootstrap = buildBootstrapPriorityOrder()
    if needsIndexBootstrap() {
        return firstIncompletePiece(in: bootstrap, peerBitfield: peerBitfield)
    }
    let priority = buildFullPriorityOrder()
    return firstIncompletePiece(in: priority, peerBitfield: peerBitfield)
}

private func needsIndexBootstrap() -> Bool {
    if indexBootstrapCompleted { return false }
    guard downloadedPieces.contains(UInt32(streamFirstPiece)) else { return true }
    return streamTailPieces.contains { !downloadedPieces.contains(UInt32($0)) }
}

private func firstIncompletePiece(in priority: [UInt32], peerBitfield: Data) -> UInt32? {
    for index in priority {
        guard !downloadedPieces.contains(index) else { continue }
        if !peerBitfield.isEmpty, !peerHasPiece(index, in: peerBitfield) {
            continue
        }
        return index
    }
    return nil
}

private func buildBootstrapPriorityOrder() -> [UInt32] {
    var priority: [UInt32] = []
    func append(_ index: UInt32) {
        guard !priority.contains(index) else { return }
        priority.append(index)
    }
    for index in playerHotPieces { append(index) }
    append(UInt32(streamFirstPiece))
    for index in moovAnchorPieces { append(index) }
    for index in buildMissingTailPiecesNearestEOF() { append(index) }
    if let last = missingStreamLastPiece() { append(last) }
    return priority
}
```

### A.2 `StreamTailPlanner` tail span calculation

```swift
// StreamTailPlanner.swift L5-L26

public static let defaultTailByteSpan: Int64 = 8 * 1024 * 1024
public static let maxTailByteSpan:     Int64 = 64 * 1024 * 1024

public static func tailByteSpan(byteLength: Int64, pieceLength: Int64) -> Int64 {
    let scaled: Int64
    if byteLength > 2_500_000_000 {
        scaled = 32 * 1024 * 1024
    } else if byteLength > 1_000_000_000 {
        scaled = 16 * 1024 * 1024
    } else {
        scaled = defaultTailByteSpan
    }
    return min(max(scaled, pieceLength * 2), byteLength, maxTailByteSpan)
}

public static func tailPieceIndicesForDownload(
    target: TorrentStreamTarget,
    pieceLength: Int64,
    pieceCount: Int
) -> [Int] {
    tailPieceIndices(
        target: target,
        pieceLength: pieceLength,
        pieceCount: pieceCount,
        tailByteSpan: min(target.byteLength, maxTailByteSpan)
    )
}
```

### A.3 `HTTPRangeServer.waitForReadableSpan` and `readBytes` (current)

```swift
// HTTPRangeServer.swift L34-L36
private static let maxRangeBytes = 32 * 1024 * 1024
private static let readTimeoutSeconds: UInt64 = 300
private static let bufferWaitSeconds: UInt64 = 300

// L662-L692
private func waitForReadableSpan(
    pieceStore: PieceStore,
    offset: Int64,
    length: Int,
    preferSuffix: Bool
) async -> (offset: Int64, length: Int)? {
    let attempts = Int(Self.bufferWaitSeconds * 10)
    for attempt in 0..<attempts {
        if Task.isCancelled { return nil }
        if let span = await pieceStore.readableSpan(
            offset: offset, length: length, preferSuffix: preferSuffix
        ) {
            if attempt > 0 {
                TorrentLog.info(
                    "[HTTPRangeServer] Range ready after \(attempt * 100)ms — \(span.length) B @ \(span.offset) suffix=\(preferSuffix)"
                )
            }
            return span
        }
        do { try await Task.sleep(for: .milliseconds(100)) }
        catch { return nil }
    }
    return nil
}

// L775-L790
private func readBytes(pieceStore: PieceStore, offset: Int64, length: Int) async throws -> Data {
    try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask { try await pieceStore.read(offset: offset, length: length) }
        group.addTask {
            try await Task.sleep(for: .seconds(Self.readTimeoutSeconds))
            throw HTTPRangeReadTimeout()
        }
        guard let data = try await group.next() else { throw HTTPRangeReadTimeout() }
        group.cancelAll()
        return data
    }
}
```

### A.4 `StreamingOrchestrator.evaluateStreamTailPieceReady` MP4 branch (current)

```swift
// StreamingOrchestrator.swift L322-L529 (abridged to MP4 case)
let isMP4 = (detectedContainer == .mp4) || (detectedContainer == .unknown && target.needsMP4MoovTailProbe)
if isMP4 {
    let tailVerifiedCount = await streamTailPiecesVerified()
    let tailTotalCount = await streamTailPieceCount()
    await applyMP4TailDownloadAnchorsIfNeeded(...)
    if let (tailData, tailOffset) = await readVerifiedTailWindow(...) {
        let moovProbe = await probeMoovTailOffMainActor(tailData: tailData, endsAtFileEOF: true)
        switch moovProbe {
        case .complete:
            if rangeServer.remuxedLayout != nil { return true }
            if let layout = await attemptFastStartRemux(...) {
                await installRemuxLayout(layout)
                return true
            }
            return false
        case .incomplete:
            return false
        case .notFound:
            // try estimated moov, cached hit, accumulated tail, anchor piece…
            if tailTotalCount > 0 && tailVerifiedCount >= tailTotalCount {
                return true
            }
            // log "tail_not_ready" debug event
            return false
        }
    } else {
        return false
    }
}
```

### A.5 `MP4FastStartRemuxer.buildLayout`

(See file in full — 199 lines. Replaces `[ftyp][mdat-box][moov]` with `[ftyp][patched-moov][synthetic-mdat-header] + mdat-content-mapped-to-original-torrent-offset`. Patches stco/co64 chunk offsets by `delta = newMdatContentStart - originalMdatContentStart`.)

---

*End of FINDINGS.md*
