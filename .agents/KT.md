# MovieBox Knowledge Transfer: CoreStreaming & Torrent Playback Architecture

Welcome to the MovieBox CoreStreaming Knowledge Transfer (KT) document. This guide provides an exhaustive, "inch-by-inch" architectural breakdown of the MovieBox pure-Swift BitTorrent streaming client. Designed as the primary developer onboarding resource, it details how the application bootstraps torrent metadata, manages TCP/UDP peer networks, prioritizes block downloads for media playback, and streams media content to AVPlayer via a local loopback HTTP Range Server.

**Playback pipeline — full Swift source (no truncation):** [KT-source-appendix.md](./KT-source-appendix.md). **Playback-focused walkthrough:** [../KT.md](../KT.md).

---

## 1. Subsystem Architecture Overview

The CoreStreaming framework is implemented in pure Swift, using modern Swift concurrency (Actors, Tasks, and unstructured structured task loops) and Apple's Network framework (`NWConnection` and `NWListener`). It operates completely in user space without external C bindings (such as `libtorrent`).

The following diagram illustrates the relationship between the major components of the streaming engine during an active playback session:

```
┌────────────────────────────────────────────────────────────────────────┐
│                              AVPlayer                                  │
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │ HTTP Range Requests
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│                          HTTPRangeServer                               │
│  - Listens on 127.0.0.1:PORT                                           │
│  - Receives GET/HEAD requests                                          │
│  - Translates media byte ranges to absolute torrent piece/block offsets│
└──────┬──────────────────────────────────────────────────────────┬──────┘
       │                                                          │
       │ Reads verified or                                        │ Boosts priority of
       │ contiguous unverified                                    │ requested ranges
       │ blocks from disk                                         │
       ▼                                                          ▼
┌──────────────────────────────┐                           ┌─────────────┐
│          PieceStore          │                           │PieceManager │
│  - Filesystem handles        │                           │ - Priority  │
│  - Pre-allocated storage file│                           │   queues    │
│  - Verified piece bitmap     │                           │ - In-flight │
│  - Contiguous head track     │                           │   requests  │
└──────────────▲───────────────┘                           └──────▲──────┘
               │                                                  │
               │ Writes received blocks                           │ Yields next
               │ and marks verified pieces                        │ block index
               └───────────────────────┬──────────────────────────┘
                                       │
                              PieceIngestion.apply()
                                       │
                                       ▲
┌────────────────────────────────────────────────────────────────────────┐
│                            TorrentEngine                               │
│  - Handles HTTP/UDP tracker announces and DHT peer scouting            │
│  - Spawns and manages PeerConnection sessions                          │
│  - Coordinates the sliding window of block request pipelines           │
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │
                    ┌──────────────┴──────────────┐
                    ▼                             ▼
             [PeerConnection 1]            [PeerConnection N]
             - Handshake, bitfield         - Handshake, bitfield
             - TCP socket read loop        - TCP socket read loop
```

### Core Subsystems and Responsibility Mapping

1. **`AppBootstrap` & `TorrentPlaybackCoordinator`**: Intermediaries between the SwiftUI lifecycle and CoreStreaming. They initialize the engine, check network status, resolve TMDB identifiers, and clean up temporary storage.
2. **`TorrentMetadataFetcher`**: Handles resolving magnet URIs into parsed metadata (`TorrentMetadata`). It queries a Hono proxy backend, peer swarms (`UTMetadataFetcher`), and public Web mirrors.
3. **`UTMetadataFetcher`**: Implements BEP 9 (Extension for Transferring Metadata) to download the `.torrent` file's info-dictionary directly from peers using the wire protocol.
4. **`TorrentEngine`**: Manages the life cycle of trackers, DHT, and the active set of peer connections (up to 64 concurrent peers).
5. **`PeerConnection`**: Manages an individual TCP connection to a peer, parses incoming packets into typed messages, and handles the sliding pipeline of outstanding block requests.
6. **`PieceManager`**: Decides which piece and block to download next. It maintains a strict priority queue based on player seeks (Hot Pieces), head pieces (Bootstrap), and tail pieces (Index Probe).
7. **`PieceStore`**: Coordinates reading and writing to the disk. It supports writing unverified blocks directly to the disk for low-latency playback while tracking piece verification status.
8. **`HTTPRangeServer`**: A light HTTP 1.1 server running on a local TCP port that intercepts player range requests and serves them from the `PieceStore`, parking connection threads until data is ready.

---

## 2. Bootstrapping Phase: Magnet to Metadata

When a stream starts, the only information available is typically a magnet URI. This URI contains:
- An **Info Hash**: A 20-byte SHA-1 hash that uniquely identifies the torrent swarm.
- An **Announce List**: Trackers that index peers participating in the swarm.
- A **Display Name**: Text string indicating the torrent title.

Because a magnet link contains no details about files, byte layouts, or piece boundaries, the app must resolve the info hash into a full `TorrentMetadata` dictionary before streaming can begin.

### Execution Sequence in `TorrentMetadataFetcher`

The resolution of a magnet link is driven by `TorrentMetadataFetcher.fetch(infoHash:magnetTrackers:)`. To bypass slow swarms, the fetcher runs three distinct strategies in parallel using a Swift `withThrowingTaskGroup`:

```
                       TorrentMetadataFetcher.fetch()
                                     │
                 ┌───────────────────┼────────────────────┐
                 ▼                   ▼                    ▼
        Cloudflare Backend      UTMetadataFetcher     Public Mirrors
         (12s Timeout)         (35s P2P Wire)         (15s HTTP)
```

1. **Backend Cache Lookup** (`fetchTorrentBytesFromBackend`):
   - Queries the Hono middleware proxy running on Cloudflare Workers.
   - If a previous user has resolved this torrent, the backend stores the complete bencoded `.torrent` file in Cloudflare KV.
   - If found, it returns the raw bencoded file, bypassing P2P handshakes completely.

2. **Public Metadata Mirrors** (`fetchFirstMirror`):
   - Fires concurrent HTTP GET requests to Web repositories:
     - `http://torrage.info/torrent.php?h={infoHash}`
     - `https://itorrents.org/torrent/{infoHash}.torrent`
     - Proxy endpoints to bypass school/ISP SNI firewalls.
   - If a mirror responds with a valid file, it is bencode-parsed, verified against the expected info hash, and returned.

3. **P2P Swarm Fetcher** (`UTMetadataFetcher`):
   - If backend caches and Web mirrors fail, the engine joins the swarm directly to query peers for the info-dictionary (BEP 9).
   - This process is split into peer discovery, handshake negotiation, and piece assembly.

### P2P Wire Metadata Fetching (`UTMetadataFetcher`)

The P2P metadata fetcher is implemented in `UTMetadataFetcher.swift`. The sequence operates as follows:

```
[UTMetadataFetcher]            [Tracker / DHT]              [Swarm Peer]
        │                              │                          │
        ├────── Discover Peers ───────>│                          │
        │<───── Return Peer List ──────┤                          │
        │                                                         │
        ├────────────────────── TCP Connect ─────────────────────>│
        │<───────────────────── TCP Ready ────────────────────────┤
        │                                                         │
        ├────────────────── BitTorrent Handshake ────────────────>│
        │  (Reserved bit 20 set to indicate extensions)           │
        │<───────────────── BitTorrent Handshake ─────────────────┤
        │                                                         │
        ├────────────── Extended Message (ID 0) ─────────────────>│
        │  (Announces support for ut_metadata)                    │
        │<───────────── Extended Message (ID 0) ──────────────────┤
        │  (Offers metadata size: e.g. 32768 B)                   │
        │                                                         │
        ├────────────── Request Piece (msg_type: 0) ─────────────>│
        │<───────────── Transmit Piece (msg_type: 1) ─────────────┤
        │                                                         │
        ├────────────────────── Close TCP ───────────────────────>│
```

#### Step 1: Peer Discovery
`UTMetadataFetcher.discoverPeers` queries both trackers (UDP & HTTP) and Kademlia DHT in parallel. It issues quick announce requests with a `left = 1` and `numWant = 80` payload. 
- Trackers are announced using a timeout cap of 4 seconds.
- As soon as 32 unique peers are discovered, the discovery loop cancels all outstanding tracker requests and exits to conserve bandwidth.

#### Step 2: TCP Connection and Handshake
For the top 6 discovered peers, `UTMetadataFetcher` instantiates an actor-isolated `MetadataPeerSession`. The session initiates a standard TCP connection using the Network framework:
- It establishes a connection to the remote port.
- It prepares a 68-byte BitTorrent handshake payload:
  ```
  Byte 0: 19 (length of protocol identifier)
  Bytes 1-19: "BitTorrent protocol"
  Bytes 20-27: Reserved bits (BEP 10 extension negotiation)
  Bytes 28-47: Info hash (20 bytes)
  Bytes 48-67: Generated peer ID (20 bytes)
  ```
- To signal that the client supports the BitTorrent Extension Protocol (BEP 10), it modifies the reserved bytes:
  `reserved[5] |= 0x10` (the 20th bit from the right is toggled).

#### Step 3: Extension Negotiation
Once both handshakes are verified, the client transmits an **Extended Handshake** message. BitTorrent extended messages use a message ID of `20`. The payload is a bencoded dictionary:
```
d1:md11:ut_metadatai1ee4:reqqi255ee
```
This decodes to:
- `m`: A sub-dictionary mapping extension names to local message IDs. Here, we register `ut_metadata` with local ID `1`.
- `reqq`: Max outstanding request queue length (set to 255).

The peer responds with their own extended handshake dictionary:
```
d1:md11:ut_metadatai2ee13:metadata_sizei32768ee
```
From this response, the client extracts:
- `utMetadataExtensionID`: The remote message ID that we must use to request metadata pieces (here, `2`).
- `metadata_size`: The total size in bytes of the torrent info-dictionary (here, `32,768` bytes).

#### Step 4: Metadata Piece Request Loop
The metadata info-dictionary is split into chunks of `16,384` bytes (16 KB). The client loops through the required piece indices (e.g. piece 0 and piece 1 for a 32 KB metadata payload) and sends request messages:
- **Extended Request Message ID**: `20` (Extended Message)
- **Extension ID**: The ID provided by the peer (e.g., `2`)
- **Bencoded Payload**:
  ```
  d8:msg_typei0e5:piecei0ee
  ```
  Where `msg_type = 0` indicates `request` (BEP 9).
  
The peer responds with a message containing bencoded headers followed immediately by the raw metadata bytes:
- **Bencoded Header**:
  ```
  d8:msg_typei1e5:piecei0ee
  ```
  Where `msg_type = 1` indicates `data`.
- **Payload**: The 16 KB segment of the info-dictionary.

#### Step 5: Assembly and Validation
Once all pieces are downloaded, the client concatenates them and computes the SHA-1 hash of the assembled data. If the computed hash matches the target info hash, it parses the data as a bencoded dictionary, extracts the file structure, and returns the resolved `TorrentMetadata`. If the hash matches, the task group cancels all other peer sessions.

---

## 3. Stream Targeting & Prioritization Planning

Once metadata is available, the client identifies the target file and calculates the necessary byte boundaries.

### Selecting the Media File (`TorrentStreamTarget`)

Torrents often contain multiple files (e.g., video file, subtitle files, text files, and images). `TorrentStreamTarget.selectPrimary(from:)` scans the file list in the metadata and identifies the primary video file based on the following rules:
- Excludes files inside directories commonly named `Sample` or containing `sample` in the filename.
- Filters files with video extensions: `.mp4`, `.mkv`, `.avi`, `.mov`, `.webm`, `.m4v`.
- Selects the file with the largest file size among the remaining candidates.

The selected file's byte layout is mapped to the torrent's piece layout:
- `byteOffset`: The starting byte of this file relative to the absolute start of the torrent.
- `byteLength`: The size of the file in bytes.
- `firstPieceIndex`: `Int(byteOffset / pieceLength)`
- `lastPieceIndex`: `Int((byteOffset + byteLength - 1) / pieceLength)`

### MP4 Fast-Start vs. Trailing Moov (Tail Planning)

For video playback, the player (`AVPlayer`) cannot decode the media stream without reading the container file index.
- **Fast-Start MP4**: The file index (`moov` atom) is located at the beginning of the file, preceding the media payload (`mdat` atom). The player can begin rendering as soon as the first few pieces are buffered.
- **Matroska (MKV / WebM)**: Tracks and cluster index tables (`cues`) are typically placed at the end of the file.
- **Standard MP4 / MOV**: The `moov` atom is frequently written at the end of the file (trailing moov) when created by camera captures or standard transcoder pipelines.

If the file index is at the tail of the file and the client only downloads sequentially from the start, `AVPlayer` will hang, request the end of the file, and stall if the range server returns a `503 Buffering` or parks the thread.

To prevent this, `StreamTailPlanner.swift` calculates the tail pieces that must be downloaded alongside the start pieces before playback can be declared ready.

```
       Torrent Byte Range
      ┌────────────────────────────────────────────────────────┐
      │   Head Pieces (0-5)   │      Middle Pieces     │  Tail │
      └──────────┬────────────┘                        └───┬───┘
                 │                                         │
                 ▼                                         ▼
         Playback Startup                          moov atom / Cues
```

#### Tail Piece Calculations
1. **Determining the Byte Window**:
   `StreamTailPlanner.tailByteSpan` calculates the tail search window based on the file size. For large video files, it searches the last 2 MB to 5 MB of the file.
2. **Mapping to Piece Indices**:
   The byte span is mapped to absolute piece indices at the end of the target file.
3. **Moov Tail Probing**:
   During buffering, `isStreamTailPieceReady()` reads the tail window using `PieceStore.read(...)`. It scans the byte buffer for the `moov` atom string (`[0x6d, 0x6f, 0x6f, 0x76]`).
   - If the `moov` atom is found and is complete (i.e. its length header fits within the tail pieces already downloaded), the tail is declared ready.
   - If the file is identified as a Fast-Start MP4 (because the `moov` atom is detected within the first 512 KB of the head), tail verification is bypassed.

---

## 4. The Torrent Engine & Peer Network Loop

`TorrentEngine` is a `@MainActor` class that coordinates the peer connection network. It initiates tracker requests, handles DHT lookups, maintains the active peer array, and monitors transferring speeds.

### Announce Mechanisms (HTTP & UDP)

To populate the peer database, `TorrentEngine` announces the client's availability to trackers in parallel. Trackers can use either HTTP or UDP.

#### HTTP Trackers (`TrackerClient`)
HTTP announcements are executed via GET requests. The request query parameters must be formatted carefully. In particular, the 20-byte raw info hash and peer ID must be percent-encoded directly without using standard URL encoding libraries (which convert hex sequences into double-encoded or uppercase sequences that HTTP trackers reject).
Example query:
```
http://tracker.example.com/announce?info_hash=%0a%b4%1c%2d...&peer_id=-MB1000-...&port=6881&uploaded=0&downloaded=0&left=1048576&compact=1&event=started
```

#### UDP Trackers (`UDPTrackerClient`)
Because UDP is connectionless, announcing to a UDP tracker (`udp://...`) requires a two-step handshake process to prevent IP spoofing:

```
[UDPTrackerClient]                                             [UDP Tracker]
        │                                                            │
        ├────── Connection Request ─────────────────────────────────>│
        │  - Protocol ID: 0x41727101980                            │
        │  - Action: 0 (connect)                                     │
        │  - Transaction ID: random_32_bit                           │
        │                                                            │
        │<───── Connection Response ─────────────────────────────────┤
        │  - Action: 0                                               │
        │  - Transaction ID: matched_32_bit                          │
        │  - Connection ID: 64_bit_key                               │
        │                                                            │
        ├────── Announce Request ───────────────────────────────────>│
        │  - Connection ID: 64_bit_key                               │
        │  - Action: 1 (announce)                                    │
        │  - Transaction ID: new_random_32_bit                       │
        │  - Info Hash, Peer ID, Down, Left, Up, Port, num_want      │
        │                                                            │
        │<───── Announce Response ───────────────────────────────────┤
        │  - Action: 1                                               │
        │  - Transaction ID: matched_32_bit                          │
        │  - Interval, Leechers, Seeders, Compact Peer List          │
```

1. **Connection Step**:
   - Sends a packet to the tracker port containing:
     - `protocol_id`: `0x417270101980` (constant)
     - `action`: `0` (connect)
     - `transaction_id`: A random 32-bit integer.
   - The response contains the matched `transaction_id` and a 64-bit `connection_id`.
   - The connection ID is cached for 60 seconds.

2. **Announce Step**:
   - Sends a packet containing:
     - `connection_id`: The 64-bit ID received in step 1.
     - `action`: `1` (announce)
     - `transaction_id`: A new random 32-bit integer.
     - `info_hash`: 20-byte torrent hash.
     - `peer_id`: 20-byte client peer ID.
     - `downloaded`: 64-bit integer of total bytes written.
     - `left`: 64-bit integer of remaining bytes to download.
     - `uploaded`: 64-bit integer of bytes uploaded.
     - `event`: 32-bit integer (0: none, 1: completed, 2: started, 3: stopped).
     - `port`: 16-bit integer (usually `6881`).
     - `num_want`: 32-bit integer (e.g. `80`).
   - The response is a compact binary list of peers, where each peer is represented by 6 bytes: 4 bytes for the IPv4 address and 2 bytes for the port in network byte order (big-endian).

### Kademlia DHT Integration (`KademliaDHT`)

If the tracker returns fewer than 5 active peers, `TorrentEngine` boots `KademliaDHT.swift`.
- **Port Binding**: Binds to UDP port `6882` locally.
- **Routing Table Bootstrap**: Sends `find_node` queries to public bootstrap routers (e.g., `router.bittorrent.com`, `dht.transmissionbt.com`).
- **Distributed Peer Discovery**:
  - Sends a `get_peers` RPC request to nodes closest to the torrent's info hash.
  - Nodes respond with either a list of compact peers (`values`) or a list of closer nodes (`nodes`).
  - If the node returns closer nodes, the DHT engine queries those nodes recursively.
  - Once peers are returned, they are added to the connection queue.

### Peer Wire Flow Control & Sliding Request Window (`PeerConnection`)

Each peer TCP connection is managed by `PeerConnection.swift`. To maximize download speeds without saturating the peer's socket buffer, the client implements a sliding request window.

#### State Machine Transitions
During its lifetime, a connection transitions through the following states:
```
  [connecting] ──(TCP handshake)──> [handshaking] ──(BitTorrent handshake)──> [connected]
                                                                                   │
     ┌─────────────────────────────────────────────────────────────────────────────┘
     ▼
  [choked] <──(Receive choke/unchoke messages)──> [unchoked] ──(Send block request)──> [downloading]
```

#### Message Parser (`parseNextMessageFromBuffer`)
Incoming raw bytes on the TCP socket are accumulated in `PeerConnectionBuffer`. The parser runs in a loop:
1. Reads the first 4 bytes to decode the big-endian 32-bit message length header.
2. If `length == 0`, it is treated as a `keepAlive` packet and discarded.
3. If `length > 262,144` (256 KB), the parser assumes a protocol desynchronization or encrypted payload, throws an error, and disconnects the peer.
4. Waits until the buffer contains `4 + length` bytes.
5. Decodes the 5th byte as the `messageId` and routes the payload to `handleMessage()`.

#### The Sliding Window Pipeline (`maxOutstanding`)
If the client is unchoked, it keeps multiple block requests in-flight simultaneously. 
- **Start Value**: Starts with a pipeline limit of 12 outstanding blocks (`maxOutstanding = 12`).
- **Dynamic Adjustments**: When a block is received, it calculates the round-trip-time (RTT) of the block request:
  - If `RTT < 0.35` seconds (350 ms), the connection is fast. It increases the pipeline limit:
    `maxOutstanding = min(28, maxOutstanding + 1)`
  - If `RTT > 1.2` seconds, network congestion is detected. It decreases the pipeline limit:
    `maxOutstanding = max(4, maxOutstanding - 1)`
- **Request Loop**: `requestPieces()` queries `PieceManager.getNextRequest(peerBitfield:)` for the next required block index and transmits `request` messages until the number of outstanding requests matches `maxOutstanding`.

#### Stalled Request Recovery
If a peer connection fails to deliver a requested block within `3.5` seconds, the request is marked as stalled. The connection actor:
1. Removes the block from its `outstandingRequests` list.
2. Returns the request back to the `PieceManager` queue via `recycleRequests()`.
3. Triggers another request pass. This allows other, faster peers to pick up and download the stalled block.

---

## 5. Piece Selection & Disk Storage Lifecycle

Managing disk access during real-time streaming requires a balance between speed (writing blocks immediately to allow playback) and data integrity (preventing the player from loading corrupted data).

### Prioritization Algorithms in `PieceManager`

`PieceManager` calculates download priority using three distinct search strategies depending on the stream's buffering state.

```
                  Earliest Incomplete Piece Calculation
                                    │
                        Is Index Bootstrap Met?
                                    │
                    ┌───────────────┴───────────────┐
                    ▼ Yes                           ▼ No
        Bootstrap Priority Order          Full Priority Order
        1. playerHotPieces                1. playerHotPieces
        2. streamFirstPiece               2. streamFirstPiece
        3. streamTailPieces (Index)       3. streamTailPieces (Index)
                                          4. Sequential pieces (Playhead -> EOF)
```

1. **Bootstrap Priority**:
   Until the player bootstrap conditions are met (meaning the start piece and all tail pieces are downloaded and verified), the engine downloads only these index pieces. This prevents peers from downloading random parts of the file and ensures the player has the metadata index to start.

2. **Player Hot Pieces**:
   When the player seeks to a new location in the video, `HTTPRangeServer` records the byte offset. `PieceManager.notePlayerRead(mediaOffset:length:)` maps this offset to piece indices and places them at the front of the queue (`playerHotPieces`). It also schedules 3 pieces ahead (`readAheadPieceCount = 3`) to buffer the content immediately following the seek point.

3. **Sequential Selection**:
   If there are no hot or bootstrap pieces missing, the engine downloads sequential pieces starting from the current playback playhead to the end of the file.

### Writing Blocks to Disk (`PieceStore`)

To write blocks efficiently without blocking the network thread, `PieceStore.swift` uses a write cache and immediate writes:

1. **Immediate Write for Playback**:
   When a 16 KB block is received, it is written immediately to the pre-allocated stream file via `writeBlock(...)` before the parent piece is verified. This allows `HTTPRangeServer` to read and stream the data immediately.

2. **Advancing the Contiguous Stream Head**:
   If the written block connects to the start of the file or is contiguous with the current end of the stream head (`streamHeadContiguousEnd`), the head position is updated. The Range Server uses this index to determine how much data can be served immediately.

3. **Write Cache**:
   Blocks are added to an in-memory array (`writeCache`). When the cache reaches `2 MB` (`maxCacheSize`), it flushes all cached blocks to disk using a single write operation, reducing disk I/O overhead.

### Piece Verification & Rollback

When all blocks for a piece are written:
1. `PieceIngestion` reads the assembled piece from the temporary cache buffer.
2. It calculates the SHA-1 hash of the block.
3. It compares the hash to the target hash in `piecesHash`.
4. **On Verification Success**:
   The piece is registered in the `bitmap` array. The temporary buffer memory is freed.
5. **On Verification Failure (Hash Mismatch)**:
   If the hash does not match (due to transmission errors or corrupt blocks), `PieceStore.invalidatePiece(pieceIndex:)` is triggered:
   - Removes any pending writes for this piece from the write cache.
   - Seeks to the piece's position on disk and overwrites its bytes with zeros.
   - Clears the piece index from the verified bitmap.
   - Recalculates the contiguous unverified stream head (`recomputeStreamHeadContiguousEnd()`).
   - This prevents the player from reading corrupt video frames.

---

## 6. HTTP Range Server: Interfacing with AVPlayer

The player (`AVPlayer`) interacts with the stream via standard HTTP 1.1 Range requests. `HTTPRangeServer.swift` handles these incoming TCP connections.

### Connection Architecture
The server is powered by `NWListener`. It binds to loopback address `127.0.0.1` and uses a dynamic port.
- **Request Parsing**: Reads headers until it detects the HTTP CRLF sequence (`\r\n\r\n`).
- **Security Check (DNS Rebinding Protection)**:
  To prevent external websites from reading the media stream using local requests, the server inspects the HTTP `Host` header.
  ```swift
  let allowedHosts: Set<String> = ["127.0.0.1", "localhost", ""]
  let bareHost = hostHeader.components(separatedBy: ":").first ?? ""
  guard allowedHosts.contains(bareHost) else {
      return HTTPResponse(status: 403, body: "Forbidden")
  }
  ```
  If the host is not a loopback address, the request is rejected with a `403 Forbidden` response.

### Range Request Parsing

The server parses the `Range:` header using regular expressions or string splits:
- **Standard Range**: `bytes=50000-100000` (requests a specific byte window).
- **Open-Ended Range**: `bytes=20000-` (requests all data from offset `20000` to the end of the file).
- **Suffix Range**: `bytes=-8000` (requests the last `8000` bytes of the file, common when the player probes for trailing indexes).

To prevent large buffer reads from causing latency or memory spikes, the server caps the response size to `2 MB` (`maxRangeBytes = 2 * 1024 * 1024`).

### Serving Suspended Responses

If the player requests a range that is not yet downloaded, returning an HTTP error will cause `AVPlayer` to fail. Instead, the range server parks the connection thread using `waitForReadableSpan(...)`:

```swift
private func waitForReadableSpan(
    pieceStore: PieceStore,
    offset: Int64,
    length: Int,
    preferSuffix: Bool
) async -> (offset: Int64, length: Int)? {
    let attempts = Int(Self.bufferWaitSeconds * 10) // 300 seconds * 10 attempts/sec
    for attempt in 0..<attempts {
        if Task.isCancelled { return nil }
        
        // Checks both the verified bitmap and the contiguous unverified head
        if let span = await pieceStore.readableSpan(offset: offset, length: length, preferSuffix: preferSuffix) {
            return span
        }
        
        // Suspend the current execution task for 100ms before retrying
        try? await Task.sleep(for: .milliseconds(100))
    }
    return nil
}
```

By delaying the response, the server keeps the connection open while the engine prioritized downloading the missing blocks. Once the blocks are written to disk, the loop detects the readable data, reads it from disk, and sends it to the player with an HTTP `206 Partial Content` status.

---

## 7. Playback Startup Sequence (Line-by-Line Execution)

The following sequence diagram outlines the chronological flow of execution when a user taps the "Play" button in the UI:

```
[UI / View]        [Playback Coord]       [Orchestrator]         [Engine]          [Range Server]      [AVPlayer]
    │                     │                      │                  │                    │                 │
    ├───── Play ─────────>│                      │                  │                    │                 │
    │                     ├───── startStream ───>│                  │                    │                 │
    │                     │                      ├─ fetchMetadata ─>│                    │                 │
    │                     │                      │  (P2P / Web)     │                    │                 │
    │                     │                      │<─ metadata ──────┤                    │                 │
    │                     │                      │                  │                    │                 │
    │                     │                      ├─ Create Store ──>│                    │                 │
    │                     │                      ├─ Create Manager ─>│                    │                 │
    │                     │                      │                  │                    │                 │
    │                     │                      ├───── start ─────>├─ Tracker announce ─┤                 │
    │                     │                      │                  ├─ Connect peers     │                 │
    │                     │                      │                  │  & start download  │                 │
    │                     │                      │                  │                    │                 │
    │                     │                      ├───────────── start HTTP server ──────>│                 │
    │                     │                      │<──────────── local URL ───────────────┤                 │
    │                     │<──── URL ────────────┤                                       │                 │
    │                     │                                                              │                 │
    │                     ├────────────────────────── Instantiate AVPlayer ───────────────────────────────>│
    │                     │                                                              │                 │
    │                     │                                                              │<─ GET /stream ──┤
    │                     │                                                              │  (Range: 0-)    │
    │                     │                      │                  │                    ├─ notePlayerRead │
    │                     │                      │                  │                    │  (Hot Pieces)   │
    │                     │                      │                  │                    ├─ Wait for data  │
    │                     │                      │                  │                    │  ...            │
    │                     │                      │                  │                    ├─ Send bytes ───>│
    │                     │<─────────────────────── Player Ready ──────────────────────────────────────────┤
```

### Detailed Execution Flow

#### 1. Interface Initialization
The user clicks a media release in the UI, triggering `startStream(torrent:progressHandler:)` on `StreamingOrchestrator`.

#### 2. Metadata Fetching
- Line 37: Generates a new client peer ID.
- Line 49: Launches `TorrentMetadataFetcher.fetch` within an isolated, user-initiated task.
- Once the metadata payload is downloaded, the parser processes the file layouts and returns a `TorrentMetadata` instance.

#### 3. Storage Allocation
- Line 69: Selects the primary media file (`TorrentStreamTarget`).
- Line 71: Calculates tail piece indices using `StreamTailPlanner`.
- Line 99: Initializes `PieceStore`. The actor calculates the expected file size, checks for existing bitmaps, and allocates the required disk space by truncating the file handle:
  `try handle.truncate(atOffset: UInt64(resolvedTotalSize))`

#### 4. Engine Bootstrapping
- Line 121: Initializes `PieceManager` with the target file configuration and piece hash list.
- Line 135: Initializes the `TorrentEngine` engine.
- Line 145: Attaches a callback on `rangeServer.onPlayerRead` to trigger `engine.refreshDownloadPriorities()` whenever the player requests data, ensuring the engine updates piece download priorities dynamically.
- Line 149: Launches the network socket loops on the engine:
  - UDP announcement loop starts.
  - Active peer TCP handshakes initiate.
- Line 150: Launches the `HTTPRangeServer` TCP listener.

#### 5. Player Handshake
- The orchestrator returns the local loopback URL (e.g., `http://127.0.0.1:8080/stream`).
- The coordinator instantiates `AVPlayer` with this URL.
- `AVPlayer` sends its first HTTP requests to the range server:
  1. A `HEAD` request to query file size and range support.
  2. A `GET` request with range `bytes=0-` to fetch the container file header.

#### 6. Buffering Phase
- The range server receives the `GET` request at offset `0`.
- It notifies `PieceManager` of the read range. The manager adds the first piece to the top of the `playerHotPieces` list.
- The engine prioritizes block requests for the first piece.
- Concurrently, `AVPlayer` sends a suffix range request (e.g. `bytes=-32768`) to read the end of the file. The range server blocks this request while the engine downloads the tail pieces.
- Once both the head and tail pieces are written to disk, the range server releases the suspended requests, sending the data to `AVPlayer`. The player begins decoding, transitions the UI state to `.ready`, and starts video rendering.

---

## 8. Subsystem Verification & Code Walks

To help developers understand the core logic, this section provides an in-depth walkthrough of key code paths within the streaming components.

### 8a. Request Handling in `HTTPRangeServer.swift`

Let's trace how an incoming request is parsed and handled starting around line 133:

```swift
private func receiveHTTPRequest(connection: NWConnection, pieceStore: PieceStore, buffer: Data = Data()) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
        guard let self else {
            connection.cancel()
            return
        }
        ...
        var requestBuffer = buffer
        if let data, !data.isEmpty {
            requestBuffer.append(data)
        }

        // Cap the accumulation buffer to prevent memory exhaustion
        if requestBuffer.count > Self.maxRequestHeaderBytes {
            connection.cancel()
            return
        }

        if let requestEnd = requestBuffer.range(of: Data("\r\n\r\n".utf8)) {
            let headerData = requestBuffer[..<requestEnd.lowerBound]
            guard let request = String(data: headerData, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let responseTask = Task { @MainActor [weak self, weak connection] in
                guard let self, let connection else { return }
                let response = await self.handleRequest(request, pieceStore: pieceStore)
                self.sendResponse(connection: connection, response: response)
            }
            ...
        }
    }
}
```

The server reads raw bytes from `NWConnection` and appends them to a temporary buffer. Once it detects the HTTP header termination sequence (`\r\n\r\n`), it parses the headers as a UTF-8 string and executes `handleRequest(...)` on the main actor.

The `handleRequest` function (starting around line 195) parses the HTTP method and validates the `Host` header to protect against DNS rebinding attacks. It then processes the `Range:` header:

```swift
if let rangeHeader = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
    let rangeParts = rangeHeader.components(separatedBy: "=")
    if rangeParts.count == 2 {
        let byteRange = rangeParts[1]
        let rangeComponents = byteRange.components(separatedBy: "-")
        let startStr = rangeComponents.first ?? ""
        let endStr = rangeComponents.count > 1 ? rangeComponents[1] : ""
        ...
        // Map media start and end based on suffix or standard ranges
        let rangeTorrentOffset = streamByteOffset + mediaStart
        ...
        await notifyPlayerRead(mediaOffset: mediaStart, length: length)

        guard let span = await waitForReadableSpan(
            pieceStore: pieceStore,
            offset: rangeTorrentOffset,
            length: length,
            preferSuffix: isSuffixRange
        ) else {
            return HTTPResponse(status: 503, body: "Buffering", retryAfterSeconds: 1)
        }

        bodyData = try await readBytes(pieceStore: pieceStore, offset: span.offset, length: span.length)
        ...
    }
}
```

If the requested bytes are not yet downloaded, `waitForReadableSpan` suspends the task. Once the engine downloads the blocks, they are read from disk using `readBytes` and returned to `AVPlayer` with an HTTP `206 Partial Content` status.

---

### 8b. Block Dispatch in `PeerConnection.swift`

Let's examine how peer block requests are scheduled starting around line 671:

```swift
private func requestPieces() async {
    guard let pieceManager, !isChoked, !peerBitfield.isEmpty else { return }

    let availableSlots = maxOutstanding - outstandingRequests.count
    guard availableSlots > 0 else { return }

    state = .downloading

    for _ in 0..<availableSlots {
        guard let request = await pieceManager.getNextRequest(peerBitfield: peerBitfield) else { break }

        outstandingRequests.insert(request)
        requestSentAt[request] = Date.now

        let message = WireMessage.request(
            pieceIndex: request.pieceIndex,
            offset: request.offset,
            length: request.length
        )
        connection?.send(content: message.encode(), completion: .contentProcessed { _ in })
    }
}
```

1. **Queue Checks**: It checks the peer's choking state and verifies that the peer has pieces available.
2. **Pipeline Calculation**: Calculates the number of available request slots based on `maxOutstanding`.
3. **Block Selection**: Calls `pieceManager.getNextRequest` to retrieve the next block index.
4. **Sending Requests**: Encodes the request as a BitTorrent wire packet and sends it over the TCP socket.

When the peer responds with the data block, the socket reader calls `handlePiece(...)` (around line 701):

```swift
private func handlePiece(pieceIndex: UInt32, offset: UInt32, block: Data) async {
    let completed = BlockRequest(pieceIndex: pieceIndex, offset: offset, length: 0)
    let sentAt = requestSentAt[completed]
    outstandingRequests.remove(completed)
    requestSentAt.removeValue(forKey: completed)
    piecesReceived += 1

    if let sentAt {
        let rtt = Date.now.timeIntervalSince(sentAt)
        // Dynamically adjust the pipeline size based on latency
        if rtt < 0.35 {
            maxOutstanding = min(28, maxOutstanding + 1)
        } else if rtt > 1.2 {
            maxOutstanding = max(4, maxOutstanding - 1)
        }
    }

    if let callback = onPieceReceived {
        await callback(pieceIndex, offset, block)
    }
    await requestPieces()
}
```

The connection calculates the block's RTT, adjusts `maxOutstanding` to adapt to network conditions, and executes `onPieceReceived` to pass the block to `PieceIngestion`. It then triggers another request pass to keep the pipeline full.

---

### 8c. Prioritization Order in `PieceManager.swift`

Let's review how `PieceManager` selects the next piece to download (starting around line 206):

```swift
private func earliestIncompletePiece(peerBitfield: Data) -> UInt32? {
    let bootstrap = buildBootstrapPriorityOrder()
    if needsIndexBootstrap() {
        return firstIncompletePiece(in: bootstrap, peerBitfield: peerBitfield)
    }

    let priority = buildFullPriorityOrder()
    return firstIncompletePiece(in: priority, peerBitfield: peerBitfield)
}

private func needsIndexBootstrap() -> Bool {
    guard downloadedPieces.contains(UInt32(streamFirstPiece)) else { return true }
    return streamTailPieces.contains { !downloadedPieces.contains(UInt32($0)) }
}
```

1. **Bootstrap Check**: If the start piece or any tail pieces are missing, the manager enforces the **Bootstrap Priority Order**.
2. **Bootstrap Queue Assembly**:
   ```swift
   private func buildBootstrapPriorityOrder() -> [UInt32] {
       var priority: [UInt32] = []
       func append(_ index: UInt32) {
           guard !priority.contains(index) else { return }
           priority.append(index)
       }

       for index in playerHotPieces { append(index) }
       append(UInt32(streamFirstPiece))
       for piece in streamTailPieces.reversed() { append(UInt32(piece)) }
       return priority
   }
   ```
   This prioritizes:
   - Pieces currently requested by the player (`playerHotPieces`).
   - The first piece of the video file (`streamFirstPiece`).
   - The tail index pieces (`streamTailPieces`).
3. **Fallback to Sequential**: Once bootstrap is complete, it appends the remaining pieces sequentially starting from the playhead.

---

### 8d. Write Management in `PieceStore.swift`

Let's examine how the client writes data to disk (starting around line 137):

```swift
public func writeBlock(pieceIndex: Int, blockOffset: Int64, data: Data) async throws {
    guard pieceIndex >= 0, pieceIndex < pieceCount else {
        throw PieceStoreError.invalidPieceIndex(pieceIndex)
    }

    let torrentOffset = Int64(pieceIndex) * pieceSize + blockOffset
    try queueWrite(torrentOffset: torrentOffset, data: data)

    let blockStart = torrentOffset
    let blockEnd = torrentOffset + Int64(data.count)
    let mediaStart = max(0, blockStart - streamMediaByteOffset)
    let mediaEnd = max(0, blockEnd - streamMediaByteOffset)
    if mediaEnd > mediaStart {
        let connectsToHead = mediaStart <= streamHeadContiguousEnd
        let isFirstBlock = pieceIndex == streamFirstPiece && blockOffset == 0
        if connectsToHead || (isFirstBlock && streamHeadContiguousEnd == 0) {
            streamHeadContiguousEnd = max(streamHeadContiguousEnd, mediaEnd)
        }
    }
}
```

`writeBlock` queues the write operation and calculates if the block connects to the start of the file or the current end of the stream head (`streamHeadContiguousEnd`). If it does, the head position is advanced, making this new range immediately readable by `HTTPRangeServer` before the full piece is verified.

---

## 9. Performance Diagnostics: Startup Bottlenecks & Playback Errors

Streaming video over a P2P protocol is prone to startup delays and playback interruptions. Below is an analysis of these bottlenecks and how the client handles them.

### Bottleneck 1: Magnet Link Resolution Latency
* **Symptom**: The UI remains stuck in the `.preparing` state for 15 to 45 seconds when playing older or low-peer releases.
* **Root Cause**: Magnet links contain no file layout information. The app must fetch the `.torrent` metadata file before it can allocate disk space or request media blocks. If the metadata is not cached on our servers, the client must locate peers via trackers or DHT, connect to them, negotiate the BitTorrent Extension Protocol (BEP 10), and request the metadata chunks over the wire.
* **Diagnostic Data**: Tracker announces can take several seconds to complete, and many home routers rate-limit UDP packets, slowing down peer discovery.

### Bottleneck 2: Trailing Moov Atom Blocks
* **Symptom**: The download speed is high, but the player stays stuck in the buffering state (90%) for a long time, eventually timing out.
* **Root Cause**: The media file has its index (`moov` atom) at the end of the file. `AVPlayer` needs this index to locate video frames and audio samples. If the tail pieces of the file are not downloaded, the range server suspends the player's request. If the client fails to download these tail pieces quickly (e.g., due to slow peers or choking), the playback hangs.
* **Diagnostic Data**: The logs show `buffering watchdog — Buffering stalled — waiting for file index (7/13 tail pieces)`.

### Bottleneck 3: AVPlayer Timeout on HTTP Range Requests
* **Symptom**: The player stops suddenly, showing a playback error, even though the engine continues to download data.
* **Root Cause**: If the range server suspends a request for too long (over 30-60 seconds) while waiting for data, `AVPlayer` will time out and close the connection. Similarly, if the server returns a `503 Buffering` response too many times, the player treats it as a network failure.
* **Diagnostic Data**: The logs show `HTTPRangeServer Range timed out after 300s — still buffering`.

### Bottleneck 4: Data Corruptions from Unverified Data Access
* **Symptom**: Video playback shows visual artifacts, audio issues, or stops with a decoding error.
* **Root Cause**: To reduce startup latency, the client allows the player to read data from the contiguous stream head before the blocks are verified. However, if a piece fails its SHA-1 hash check during verification (due to transmission errors or bad data from a peer), the engine invalidates the piece and zero-fills its block on disk. If the player has already read or is currently decoding that data, it receives corrupted frames, causing decoders to crash or fail.

---

## 10. Structural Recommendations for Performance Optimization

To improve startup speeds and reduce playback errors, we should implement the following optimizations in the `CoreStreaming` package:

### 1. Metadata and Router Caching
- **Implement Metadata Cache Persistence**:
  Save resolved `TorrentMetadata` dictionaries directly to the local application cache directory (e.g., in a JSON or plist file indexed by info hash). If the user replays a video or starts a stream that was cached, load the metadata instantly from disk, reducing startup latency to less than 100ms.
- **DHT Routing Table Persistence**:
  DHT bootstrapping can take 5 to 10 seconds on startup. Persist the DHT routing table (the list of active DHT node IPs and ports) to disk when the app closes and reload it on launch, allowing the client to query DHT peers immediately.

### 2. Aggressive Peer Scouting & Announce Pipelines
- **Prewarm Swarms on Detail Page**:
  When a user views a movie detail page, call `TorrentMetadataFetcher.prewarm(infoHash:)` in the background before they tap "Play". This resolves the metadata and bootstraps the peer list in advance, allowing the video to start playing instantly when requested.
- **Implement Peer List Persistence**:
  Cache a list of known active peer IPs and ports for popular torrents. When starting a stream, connect to these cached peers immediately while waiting for tracker responses.

### 3. Progressive Tail Loading and Remuxing
- **Prioritize Head and Tail Downloads Concurrently**:
  Modify the piece request pipeline to request blocks from both the first piece and the tail pieces simultaneously from the first second of the connection.
- **Implement Local MP4 Fast-Start Remuxing (Fast-Muxing)**:
  If we detect a trailing `moov` atom, we can parse the MP4 structure and rewrite the file layout locally in memory or on disk as the bytes arrive, moving the `moov` atom to the head of the stream before serving it to `AVPlayer`. This allows the player to start streaming without waiting for the full tail pieces to download.

---

## 11. Custom Network Protocol Frame Reference

Below is a reference of the BitTorrent wire protocol message frames exchanged by `PeerConnection` over the TCP socket. All frames start with a 4-byte big-endian length header, followed by a 1-byte message ID (except `keepAlive`).

### 1. Keep-Alive Frame (Length: 4 Bytes)
Used to keep the TCP connection alive.
```
┌───────────────────────────────┐
│     Length (0x00000000)       │
└───────────────────────────────┘
```

### 2. Choke Frame (Length: 5 Bytes)
Sent by the peer to notify the client that it will not service requests.
```
┌───────────────────────────────┬──────────────┐
│     Length (0x00000001)       │ Message ID(0)│
└───────────────────────────────┴──────────────┘
```

### 3. Unchoke Frame (Length: 5 Bytes)
Sent by the peer to notify the client that it is ready to receive requests.
```
┌───────────────────────────────┬──────────────┐
│     Length (0x00000001)       │ Message ID(1)│
└───────────────────────────────┴──────────────┘
```

### 4. Interested Frame (Length: 5 Bytes)
Sent by the client to signal interest in the peer's pieces.
```
┌───────────────────────────────┬──────────────┐
│     Length (0x00000001)       │ Message ID(2)│
└───────────────────────────────┴──────────────┘
```

### 5. Not Interested Frame (Length: 5 Bytes)
Sent by the client to signal it does not need pieces from the peer.
```
┌───────────────────────────────┬──────────────┐
│     Length (0x00000001)       │ Message ID(3)│
└───────────────────────────────┴──────────────┘
```

### 6. Have Frame (Length: 9 Bytes)
Sent by a peer to announce it has successfully verified a piece.
```
┌───────────────────────────────┬──────────────┬───────────────────────────────┐
│     Length (0x00000005)       │ Message ID(4)│      Piece Index (4-byte)     │
└───────────────────────────────┴──────────────┴───────────────────────────────┘
```

### 7. Bitfield Frame (Length: 5 + N Bytes)
Sent immediately after connection handshake to describe the peer's verified pieces.
```
┌───────────────────────────────┬──────────────┬───────────────────────────────┐
│     Length (0x00000001 + N)   │ Message ID(5)│      Bitfield Data (N-byte)   │
└───────────────────────────────┴──────────────┴───────────────────────────────┘
```

### 8. Request Frame (Length: 17 Bytes)
Sent to request a 16 KB block of data from the peer.
```
┌───────────────────┬──────────┬───────────────────┬───────────────────┬───────────────────┐
│ Length (0x0000000d│ Msg ID(6)│ Piece Index (4B)  │ Block Offset (4B) │ Block Length (4B) │
└───────────────────┴──────────┴───────────────────┴───────────────────┴───────────────────┘
```

### 9. Piece Frame (Length: 9 + Block Size Bytes)
Delivers the requested block of data back to the client.
```
┌───────────────────┬──────────┬───────────────────┬───────────────────┬───────────────────┐
│ Length (9 + Block)│ Msg ID(7)│ Piece Index (4B)  │ Block Offset (4B) │ Raw Block Data    │
└───────────────────┴──────────┴───────────────────┴───────────────────┴───────────────────┘
```

### 10. Cancel Frame (Length: 17 Bytes)
Sent to cancel a pending block request. Used when a request times out or is redistributed.
```
┌───────────────────┬──────────┬───────────────────┬───────────────────┬───────────────────┐
│ Length (0x0000000d│ Msg ID(8)│ Piece Index (4B)  │ Block Offset (4B) │ Block Length (4B) │
└───────────────────┴──────────┴───────────────────┴───────────────────┴───────────────────┘
```

### 11. Port Frame (Length: 7 Bytes)
Sent by DHT-enabled clients to advertise their local DHT port.
```
┌───────────────────────────────┬──────────────┬──────────────────────┐
│     Length (0x00000003)       │ Message ID(9)│     Port (2-byte)    │
└───────────────────────────────┴──────────────┴──────────────────────┘
```

### 12. Extended Protocol Frame (Length: 6 + N Bytes)
Negotiates extension protocol features (BEP 10).
```
┌───────────────────────────────┬──────────────┬──────────────┬────────────────────────┐
│     Length (0x00000002 + N)   │ Message ID(20│Extended ID(1B│  Bencoded Payload (N-B)│
└───────────────────────────────┴──────────────┴──────────────┴────────────────────────┘
```

---

## 13. System Configurations & Runtime Onboarding

This section details how to set up the runtime environment and debug external services connected to MovieBox.

### 13a. Sparkle Update Framework Integration
The macOS application integrates the Sparkle framework to handle auto-updates. During startup, `AppBootstrap` initializes the Sparkle controller:
- It checks the app bundle version.
- It queries the update server's XML feed (configured via the Sparkle settings key in `Info.plist`).
- If a newer version is available, Sparkle prompts the user and manages downloading and staging the installation files.

### 13b. Local Hono Proxy Gateway & Wrangler KV Caches
The proxy gateway resides in the `Backend/` directory and is built using Hono and Cloudflare Workers. It acts as an API gateway and cache:
- **Routing Queries**: Proxies and forwards requests to public endpoints (like TMDB and OMDb).
- **Metadata KV Storage**: Resolves incoming info hashes to `.torrent` structures and caches the bencoded data in Cloudflare Workers KV under the namespace binding `MOVIEBOX_CACHE`.
- **Authorization**: Validates requests by checking for a shared secret key in the `X-MovieBox-Token` HTTP header.

### 13c. TV Show Episodes Query Pipeline
To support TV Shows, the client maps seasons and episode indexes to relevant torrent names:
- **Routing Route Metadata**: Navigation structures use a `MediaKind` parameter ("movie" or "tv").
- **Episode Curation Loader**: For TV shows, `MovieDetailLoader` parses episode arrays and queries trackers with custom search patterns matching `SxxExx` or `Sxx` or `x.xx`.
- **Filtering**: Filters results by seeder counts, codec compatibility (supporting HEVC/H.264), and episode indices.

---

## 14. Verification & Local Testing Plan

To verify adjustments or validate that streaming operates correctly without regressions, use the following local testing suites:

### Automated Tests
Run the unit test suite inside `CoreStreamingTests` using `swift test` or Xcode's test runner:
```bash
# From App/CoreStreaming directory:
swift test
```
This executes tests covering:
- **`BencodeTests`**: Validates encoder/decoder logic against edge cases.
- **`PieceStoreTests`**: Validates concurrent block writing, pre-allocation truncation, and hash verification rollback.
- **`PieceManagerTests`**: Validates priority updates on player seek events.
- **`HTTPRangeServerTests`**: Spins up loopback servers to test Range header queries and connection parking.

### Manual Verification
1. Open the Sparkle-supported `MovieBox` macOS app workspace.
2. Build and run the app scheme in Xcode.
3. Access the **Developer Options HUD** within the app to monitor live logs from `LogStore`.
4. Paste a magnet link and tap play.
5. Verify the following transitions in the HUD:
   - State progresses from `.preparing` to `.buffering` (shows progress percent).
   - Trackers respond with peer addresses.
   - Buffer reaches target threshold, starts local TCP range server.
   - AVPlayer initializes and starts rendering the video stream.
   - Seeking forward in the video timeline updates the `playerHotPieces` list, triggering immediate block requests for the new playhead position.

---

This concludes the architectural knowledge transfer document. Use the references provided to guide additions and performance improvements in the MovieBox CoreStreaming module.
