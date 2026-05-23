import CoreStorage
import CoreTorrent
import Foundation

// MARK: - Streaming Orchestrator

@MainActor
public final class StreamingOrchestrator: @unchecked Sendable {
    private var pieceStore: PieceStore?
    private var pieceManager: PieceManager?
    private var rangeServer = HTTPRangeServer()
    private var torrentEngine: TorrentEngine?
    private var metadata: TorrentMetadata?
    private var streamTarget: TorrentStreamTarget?
    private var peerId: String = ""
    private var dht: KademliaDHT?
    private var fastStartWatcherTask: Task<Void, Never>?
    private var tailReadyCached: Bool?
    private var tailReadyCachedAt: ContinuousClock.Instant?
    private static let tailReadyCacheTTL: Duration = .seconds(2)
    private var moovScanVerifiedCount = -1
    private var cachedMoovHit: MoovTailHit?
    private var moovScanLogVerifiedCount = -1
    private var moovEstimateAnchorApplied = false

    private enum FileContainerType: Sendable {
        case unknown
        case mkv
        case mp4
        case other
    }

    private var detectedContainer: FileContainerType = .unknown

    public init() {}

    deinit {
        let engine = torrentEngine
        let server = rangeServer
        let store = pieceStore
        let dhtInstance = dht
        Task { @MainActor in
            engine?.stop()
            await server.stop()
            await store?.closeHandles()
            dhtInstance?.stop()
        }
    }

    public func startStream(
        torrent: TorrentResult,
        progressHandler: @escaping @Sendable (Double, Double, Int) -> Void
    ) async throws -> URL {
        detectedContainer = .unknown
        peerId = BitTorrentPeerID.make()

        let magnet = MagnetURI(from: torrent.magnetURI)
        let infoHash = torrent.infoHash ?? magnet?.infoHash
        guard let infoHash, !infoHash.isEmpty else {
            TorrentLog.warn("[Streaming] invalid magnet — no info hash for \"\(torrent.title)\"")
            throw StreamingOrchestratorError.invalidMagnetURI
        }

        TorrentLog.info("[Streaming] fetching metadata — hash=\(infoHash.prefix(8))… trackers=\(magnet?.trackers.count ?? 0)")

        do {
            metadata = try await Task.detached(priority: .userInitiated) {
                try await TorrentMetadataFetcher.fetch(
                    infoHash: infoHash,
                    magnetTrackers: magnet?.trackers ?? []
                )
            }.value
        } catch {
            TorrentLog.warn("[Streaming] metadata fetch failed — \(error.localizedDescription)")
            if error is CancellationError {
                throw StreamingOrchestratorError.metadataUnavailable("Metadata fetch was cancelled.")
            }
            throw StreamingOrchestratorError.metadataUnavailable(error.localizedDescription)
        }

        guard let metadata else {
            throw StreamingOrchestratorError.failedToInitialize
        }

        TorrentLog.info(
            "[Streaming] metadata resolved — pieceLength=\(metadata.pieceLength) pieceCount=\(metadata.pieceCount) totalSize=\(metadata.totalSize) infoHash=\(metadata.infoHash.prefix(8))…"
        )

        try TorrentLimits.validateTotalSize(metadata.totalSize)

        let target = TorrentStreamTarget.selectPrimary(from: metadata)
        streamTarget = target
        let tailPieces = StreamTailPlanner.tailPieceIndicesForDownload(
            target: target,
            pieceLength: metadata.pieceLength,
            pieceCount: metadata.pieceCount
        )
        TorrentLog.info(
            "[Streaming] Target file: \(target.file.relativePath) (\(target.byteLength) bytes, piece \(target.firstPieceIndex)+, tail pieces \(tailPieces.count))"
        )
        DebugSessionLog.purge(infoHash: String(metadata.infoHash.prefix(8)))

        let storageDir = FileManager.default.temporaryDirectory.appendingPathComponent("moviebox_streams")

        // Clean up any other old cache files to maintain exactly 1 active/recent stream file
        if let files = try? FileManager.default.contentsOfDirectory(at: storageDir, includingPropertiesForKeys: nil) {
            for file in files {
                let filename = file.lastPathComponent
                if filename.hasPrefix("moviebox_") {
                    if !filename.contains(metadata.infoHash) {
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            }
        }

        // Load existing bitmap if any
        let bitmapURL = storageDir.appendingPathComponent("moviebox_\(metadata.infoHash).bitmap")
        let existingBitmap = try? Data(contentsOf: bitmapURL)
        let recreateFile = existingBitmap == nil

        pieceStore = try await PieceStore(
            infoHash: metadata.infoHash,
            pieceCount: metadata.pieceCount,
            pieceSize: metadata.pieceLength,
            totalSize: metadata.totalSize,
            streamFirstPiece: target.firstPieceIndex,
            streamMediaByteOffset: target.byteOffset,
            storageDirectory: storageDir,
            existingBitmap: existingBitmap,
            recreateFile: recreateFile
        )

        var initialDownloaded = Set<UInt32>()
        if let existingBitmap {
            let bitmapBools = PieceStore.decodeBitmap(existingBitmap, pieceCount: metadata.pieceCount)
            for (idx, isDownloaded) in bitmapBools.enumerated() {
                if isDownloaded {
                    initialDownloaded.insert(UInt32(idx))
                }
            }
        }

        pieceManager = PieceManager(
            pieceCount: metadata.pieceCount,
            pieceLength: metadata.pieceLength,
            totalSize: metadata.totalSize,
            piecesHash: metadata.pieces,
            streamFirstPiece: target.firstPieceIndex,
            streamTailPieces: tailPieces,
            streamMediaByteOffset: target.byteOffset,
            streamMediaByteLength: target.byteLength
        )
        if !initialDownloaded.isEmpty {
            await pieceManager!.setInitialDownloadedPieces(initialDownloaded)
        }

        torrentEngine = TorrentEngine(
            metadata: metadata,
            pieceManager: pieceManager!,
            pieceStore: pieceStore!,
            peerId: peerId,
            progressHandler: progressHandler
        )

        let manager = pieceManager!
        let engine = torrentEngine!
        rangeServer.onPlayerRead = { _, _ in
            await engine.refreshDownloadPriorities()
        }

        async let engineStart: Void = engine.start()
        async let streamURL = rangeServer.start(
            pieceStore: pieceStore!,
            streamTarget: target,
            pieceManager: manager
        )
        _ = await engineStart
        let url = try await streamURL
        TorrentLog.info(
            "[Streaming] HTTP range server — \(MovieBoxFileLogger.redactURL(url)) type=\(target.contentType) mediaBytes=\(target.byteLength)"
        )

        // Spin up a watcher that synthesizes a virtual fast-start MP4 layout the
        // moment the moov atom becomes parseable from contiguous verified tail
        // pieces. This lets AVPlayer start playback after just the last 1–2
        // pieces rather than the full 8–32 MB tail span.
        startFastStartWatcher(target: target, metadata: metadata)

        return url
    }

    public func stop() async {
        fastStartWatcherTask?.cancel()
        fastStartWatcherTask = nil
        torrentEngine?.stop()
        torrentEngine = nil
        await rangeServer.stop()
        
        if let store = pieceStore, let metadata = metadata {
            let bitmapData = await store.encodedBitmap()
            let storageDir = FileManager.default.temporaryDirectory.appendingPathComponent("moviebox_streams")
            let bitmapURL = storageDir.appendingPathComponent("moviebox_\(metadata.infoHash).bitmap")
            try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
            try? bitmapData.write(to: bitmapURL)
            await store.closeHandles()
        }
        
        pieceStore = nil
        pieceManager = nil
        metadata = nil
        streamTarget = nil
        dht?.stop()
        dht = nil
    }

    public func progress() async -> Double {
        await pieceStore?.progress() ?? 0
    }

    public func contiguousPiecesFromStart() async -> Int {
        await pieceStore?.contiguousPiecesFromStart() ?? 0
    }

    public func contiguousBytesFromStreamStart() async -> Int64 {
        await pieceStore?.contiguousBytesFromStreamStart() ?? 0
    }

    public func verifiedMediaBytesFromStart() async -> Int64 {
        await pieceStore?.verifiedMediaBytesFromStart() ?? 0
    }

    public func streamHeadContiguousBytes() async -> Int64 {
        await pieceStore?.streamHeadContiguousBytes() ?? 0
    }

    public func isStreamTailPieceReady() async -> Bool {
        let now = ContinuousClock.now
        if let tailReadyCached, let tailReadyCachedAt,
           now - tailReadyCachedAt < Self.tailReadyCacheTTL {
            if tailReadyCached {
                await pieceManager?.setIndexBootstrapCompleted()
            }
            return tailReadyCached
        }
        let ready = await evaluateStreamTailPieceReady()
        if ready {
            await pieceManager?.setIndexBootstrapCompleted()
        }
        tailReadyCached = ready
        tailReadyCachedAt = now
        return ready
    }

    private func evaluateStreamTailPieceReady() async -> Bool {
        guard let pieceStore, let target = streamTarget, let metadata else { return false }
        guard target.needsTailProbeForPlayback else { return true }

        let verifiedHead = await pieceStore.verifiedMediaBytesFromStart()

        // Dynamic magic bytes container detection
        if detectedContainer == .unknown && verifiedHead >= 16 {
            if let firstBytes = try? await pieceStore.read(offset: target.byteOffset, length: 16) {
                if firstBytes.count >= 4 && firstBytes[0] == 0x1A && firstBytes[1] == 0x45 && firstBytes[2] == 0xDF && firstBytes[3] == 0xA3 {
                    detectedContainer = .mkv
                    TorrentLog.info("[Streaming] Magic byte detection: MKV container identified")
                } else if firstBytes.count >= 8 &&
                          firstBytes[4] == 0x66 && // 'f'
                          firstBytes[5] == 0x74 && // 't'
                          firstBytes[6] == 0x79 && // 'y'
                          firstBytes[7] == 0x70    // 'p'
                {
                    detectedContainer = .mp4
                    TorrentLog.info("[Streaming] Magic byte detection: MP4/MOV container identified")
                    if verifiedHead >= 512 {
                        await applyMP4TailDownloadAnchorsIfNeeded(
                            pieceStore: pieceStore,
                            target: target,
                            metadata: metadata
                        )
                    }
                } else {
                    detectedContainer = .other
                    TorrentLog.info("[Streaming] Magic byte detection: Other container identified")
                }
            }
        }

        // If the fast-start watcher has already patched the HTTP server with a
        // synthesized moov layout, playback is ready — AVPlayer reads moov from
        // memory and streams mdat progressively.
        let headThreshold = minimumHeadBytes(for: target)

        if rangeServer.remuxedLayout != nil {
            if verifiedHead >= headThreshold {
                return true
            }
        }

        guard verifiedHead >= headThreshold else { return false }

        // Fast-start MP4 (moov before mdat) — verified head is enough.
        let readLength = min(Int(verifiedHead), 512 * 1024)
        if readLength >= 64 * 1024,
           let prefix = try? await pieceStore.read(
               offset: target.byteOffset,
               length: readLength
           ),
           StreamTailPlanner.isFastStartMP4(in: prefix) {
            TorrentLog.info("[Streaming] Fast-start MP4 detected — moov before mdat in head")
            return true
        }

        let lastPiece = min(target.lastPieceIndex, metadata.pieceCount - 1)
        guard await pieceStore.hasPiece(lastPiece) else {
            TorrentLog.debug("[Streaming] Last piece \(lastPiece) not verified yet")
            return false
        }

        // MP4/MOV with trailing moov: require a complete moov in the verified tail window
        // AND a synthesized fast-start layout installed in the HTTP server.
        let isMP4 = (detectedContainer == .mp4) || (detectedContainer == .unknown && target.needsMP4MoovTailProbe)
        if isMP4 {
            let tailVerifiedCount = await streamTailPiecesVerified()
            let tailTotalCount = await streamTailPieceCount()
            TorrentLog.debug("[Streaming] MP4 tail status: \(tailVerifiedCount)/\(tailTotalCount) verified. lastPiece \(lastPiece) verified.")
            await applyMP4TailDownloadAnchorsIfNeeded(
                pieceStore: pieceStore,
                target: target,
                metadata: metadata
            )
            if let (tailData, tailOffset) = await readVerifiedTailWindow(
                pieceStore: pieceStore,
                target: target,
                metadata: metadata
            ) {
                let moovProbe = await probeMoovTailOffMainActor(tailData: tailData, endsAtFileEOF: true)
                let tailEnd = tailData.suffix(16)
                let tailEndHex = tailEnd.map { String(format: "%02x", $0) }.joined()
                let tailSpanRequired = StreamTailPlanner.tailByteSpan(
                    byteLength: target.byteLength,
                    pieceLength: metadata.pieceLength
                )
                let paddingNote = tailEnd.allSatisfy { $0 == 0x69 }
                    ? " (tail ends with 0x69 fill — moov is likely in an earlier piece)"
                    : ""
                TorrentLog.debug(
                    "[Streaming] MP4 moovProbe=\(moovProbe) tailData=\(tailData.count)B tailOffset=\(tailOffset) " +
                    "needTailSpan=\(tailSpanRequired / 1024)KB verifiedPieces=\(tailVerifiedCount)/\(tailTotalCount) " +
                    "last16bytes=\(tailEndHex)\(paddingNote)"
                )
                DebugSessionLog.event(
                    "mp4_suffix_probe",
                    location: "StreamingOrchestrator.evaluateStreamTailPieceReady",
                    data: [
                        "moovProbe": String(describing: moovProbe),
                        "suffixKB": tailData.count / 1024,
                        "tailOffset": tailOffset,
                        "verifiedPieces": tailVerifiedCount,
                        "totalPieces": tailTotalCount,
                    ]
                )
                switch moovProbe {
                case .complete:
                    if rangeServer.remuxedLayout != nil {
                        return true
                    }
                    // Synchronously synthesize + install the fast-start layout.
                    // Falling back to the watcher loop here is what produced the
                    // "ready but AVPlayer says unplayable" race.
                    if let layout = await attemptFastStartRemux(
                        pieceStore: pieceStore,
                        target: target,
                        metadata: metadata
                    ) {
                        await installRemuxLayout(layout)
                        TorrentLog.info(
                            "[Streaming] MP4 moov index verified in tail (\(tailData.count) bytes) — fast-start layout installed inline"
                        )
                        return true
                    }
                    TorrentLog.debug("[Streaming] MP4 moov probe complete but layout synthesis failed — keep buffering")
                    return false
                case .incomplete:
                    TorrentLog.debug("[Streaming] MP4 moov in tail is still incomplete")
                    return false
                case .notFound:
                    let contiguousTail = Int64(tailData.count)
                    if let layout = await tryRemuxFromEstimatedMoovOffset(
                        pieceStore: pieceStore,
                        target: target,
                        metadata: metadata
                    ) {
                        await installRemuxLayout(layout)
                        TorrentLog.info("[Streaming] MP4 fast-start remux from estimated moov offset")
                        DebugSessionLog.event(
                            "remux_from_estimate",
                            location: "StreamingOrchestrator.evaluateStreamTailPieceReady"
                        )
                        return true
                    }
                    if let moovHit = await resolveCachedMoovHit(
                        pieceStore: pieceStore,
                        target: target,
                        metadata: metadata,
                        tailVerifiedCount: tailVerifiedCount
                    ) {
                        TorrentLog.info(
                            "[Streaming] MP4 moov in verified tail piece(s) — \(moovHit.buffer.count)B buffer at media offset \(moovHit.moovBaseMediaOffset)"
                        )
                        DebugSessionLog.event(
                            "moov_per_piece_hit",
                            location: "StreamingOrchestrator.evaluateStreamTailPieceReady",
                            data: [
                                "bufferKB": moovHit.buffer.count / 1024,
                                "moovBaseMediaOffset": moovHit.moovBaseMediaOffset,
                                "verifiedPieces": tailVerifiedCount,
                            ]
                        )
                        if rangeServer.remuxedLayout != nil {
                            return true
                        }
                        if let layout = await attemptFastStartRemux(
                            pieceStore: pieceStore,
                            target: target,
                            metadata: metadata
                        ) {
                            await installRemuxLayout(layout)
                            return true
                        }
                    }
                    if let accumulated = await readAccumulatedVerifiedTailFromEOF(
                        pieceStore: pieceStore,
                        target: target,
                        metadata: metadata
                    ) {
                        let accumulatedProbe = await probeMoovTailOffMainActor(
                            tailData: accumulated.buffer,
                            endsAtFileEOF: true
                        )
                        TorrentLog.debug(
                            "[Streaming] MP4 moovProbe accumulated=\(accumulatedProbe) " +
                            "accumulatedBytes=\(accumulated.buffer.count)B fromMediaOffset=\(accumulated.bufferStartMediaOffset)"
                        )
                        if accumulatedProbe == .complete {
                            if rangeServer.remuxedLayout != nil {
                                return true
                            }
                            if let layout = await attemptFastStartRemux(
                                pieceStore: pieceStore,
                                target: target,
                                metadata: metadata
                            ) {
                                await installRemuxLayout(layout)
                                TorrentLog.info(
                                    "[Streaming] MP4 moov in accumulated tail (\(accumulated.buffer.count) bytes) — fast-start layout installed"
                                )
                                return true
                            }
                        }
                    }
                    if tailTotalCount > 0 && tailVerifiedCount >= tailTotalCount {
                        TorrentLog.info(
                            "[Streaming] MP4 moov not in \(contiguousTail / 1024)KB suffix; all \(tailTotalCount) scheduled tail pieces verified — ready for range seek"
                        )
                        return true
                    }
                    await logVerifiedTailMoovScan(
                        pieceStore: pieceStore,
                        target: target,
                        metadata: metadata,
                        lastPiece: lastPiece,
                        tailVerifiedCount: tailVerifiedCount
                    )
                    if let anchor = await findMoovAnchorPiece(
                        pieceStore: pieceStore,
                        target: target,
                        metadata: metadata
                    ) {
                        await pieceManager?.setMoovAnchorPiece(UInt32(anchor))
                        TorrentLog.info(
                            "[Streaming] MP4 moov anchor piece \(anchor) — fetching moov span " +
                            "(\(tailVerifiedCount)/\(tailTotalCount) tail verified, \(contiguousTail / 1024)KB suffix)"
                        )
                        DebugSessionLog.event(
                            "moov_anchor_piece",
                            location: "StreamingOrchestrator.evaluateStreamTailPieceReady",
                            data: ["anchorPiece": anchor, "suffixKB": contiguousTail / 1024]
                        )
                    } else if let moovOffset = await estimatedMoovMediaOffset(
                        pieceStore: pieceStore,
                        target: target,
                        metadata: metadata
                    ) {
                        let anchorPiece = Int((target.byteOffset + moovOffset) / metadata.pieceLength)
                        await pieceManager?.setMoovAnchorPiece(UInt32(anchorPiece))
                        TorrentLog.info(
                            "[Streaming] MP4 estimated moov @ media offset \(moovOffset) → piece \(anchorPiece) " +
                            "(\(tailVerifiedCount)/\(tailTotalCount) tail verified)"
                        )
                        DebugSessionLog.event(
                            "moov_estimated_anchor",
                            location: "StreamingOrchestrator.evaluateStreamTailPieceReady",
                            data: ["anchorPiece": anchorPiece, "moovMediaOffset": moovOffset]
                        )
                    } else {
                        TorrentLog.debug(
                            "[Streaming] MP4 moov not in \(contiguousTail / 1024)KB suffix — need more tail pieces " +
                            "(gap before piece \(Int(tailOffset / metadata.pieceLength))?)"
                        )
                    }
                    DebugSessionLog.event(
                        "tail_not_ready",
                        location: "StreamingOrchestrator.evaluateStreamTailPieceReady",
                        data: [
                            "suffixKB": contiguousTail / 1024,
                            "verifiedPieces": tailVerifiedCount,
                            "totalPieces": tailTotalCount,
                            "gapBeforePiece": Int(tailOffset / metadata.pieceLength),
                        ]
                    )
                    return false

                }

            } else {
                return false
            }
        }

        // MKV/WebM: require the actual EBML Cues element to be on disk, not a fraction
        // of the tail span. Cues live at the very end of the file and a 33%-of-tail
        // heuristic frequently misses them, causing AVPlayer to open the URL and die.
        let ext = (target.file.relativePath as NSString).pathExtension.lowercased()
        let isMKVLike = (detectedContainer == .mkv) || (detectedContainer == .unknown && (ext == "mkv" || ext == "webm" || target.contentType.contains("matroska")))
        if isMKVLike {
            let headRead = min(Int(verifiedHead), 256 * 1024)
            guard headRead >= 4096,
                  let headData = try? await pieceStore.read(offset: target.byteOffset, length: headRead),
                  let segmentBodyOffset = StreamTailPlanner.segmentBodyOffset(
                      in: headData,
                      fileOffset: target.byteOffset
                  ) else {
                TorrentLog.debug("[Streaming] MKV Segment not in verified head yet")
                return false
            }

            guard let (tailData, _) = await readVerifiedTailWindow(
                pieceStore: pieceStore,
                target: target,
                metadata: metadata
            ) else {
                return false
            }

            let mkvProbe = await probeMKVSeekTableOffMainActor(tailData: tailData)
            switch mkvProbe {
            case .notFound, .incomplete:
                TorrentLog.debug("[Streaming] MKV Cues not complete in tail window (\(tailData.count) bytes)")
                return false
            case .complete:
                TorrentLog.info(
                    "[Streaming] MKV mkvSeekTableProbe=.complete tailData.count=\(tailData.count) segmentBodyOffset=\(segmentBodyOffset)"
                )
            }

            guard let analysis = await analyzeMKVCuesOffMainActor(
                tailData: tailData,
                segmentBodyOffset: segmentBodyOffset
            ) else {
                TorrentLog.debug("[Streaming] MKV Cues present but cluster entries not parseable yet")
                return false
            }

            TorrentLog.info(
                "[Streaming] MKV analyzeMKVCues firstClusterOffsets=\(analysis.firstClusterOffsets) segmentBodyOffset=\(analysis.segmentBodyOffset)"
            )

            if let firstClusterRel = analysis.firstClusterOffsets.first {
                let firstClusterAbs = analysis.segmentBodyOffset + firstClusterRel
                let headWindowEnd = target.byteOffset + metadata.pieceLength * 4
                let clusterPiece = Int(firstClusterAbs / metadata.pieceLength)
                let isInHead = firstClusterAbs < headWindowEnd
                let isDownloaded = await pieceStore.hasPiece(clusterPiece)

                guard isInHead || isDownloaded else {
                    TorrentLog.debug(
                        "[Streaming] MKV first cluster at piece \(clusterPiece) (offset \(firstClusterAbs)) not downloaded yet"
                    )
                    return false
                }
            }

            TorrentLog.info(
                "[Streaming] MKV Cues + first cluster verified — ready (\(tailData.count) bytes tail, segment @ \(segmentBodyOffset))"
            )
            return true
        }

        // Generic moov-not-found fallback (other container types): require the last
        // N contiguous tail pieces from the end of the file, not a fractional threshold.
        // Cues / indexes live at the very end, so verifying the actual end is what matters.
        let tailIndices = StreamTailPlanner.tailPieceIndices(
            target: target,
            pieceLength: metadata.pieceLength,
            pieceCount: metadata.pieceCount
        )
        guard !tailIndices.isEmpty else { return true }

        let requiredContiguousFromEnd = min(tailIndices.count, 4)
        let sortedTail = tailIndices.sorted()
        var contiguousFromEnd = 0
        for index in sortedTail.reversed() {
            guard await pieceStore.hasPiece(index) else { break }
            contiguousFromEnd += 1
            if contiguousFromEnd >= requiredContiguousFromEnd { break }
        }
        return contiguousFromEnd >= requiredContiguousFromEnd
    }

    /// True only when every piece spanning the stream target file is verified on disk —
    /// used to detect a fully offline-resumable session that doesn't need network peers.
    public func allStreamPiecesVerified() async -> Bool {
        guard let pieceStore, let target = streamTarget, let metadata else { return false }
        let first = target.firstPieceIndex
        let last = min(target.lastPieceIndex, metadata.pieceCount - 1)
        guard first <= last else { return false }
        for index in first...last {
            if await !pieceStore.hasPiece(index) {
                return false
            }
        }
        return true
    }

    private func minimumHeadBytes(for target: TorrentStreamTarget) -> Int64 {
        if detectedContainer == .mkv {
            return StreamPlaybackThreshold.minimumHeadBytesForMKV
        } else if detectedContainer == .mp4 {
            return StreamPlaybackThreshold.minimumHeadBytes
        }
        let ext = (target.file.relativePath as NSString).pathExtension.lowercased()
        if ext == "mkv" || ext == "webm" || target.contentType.contains("matroska") {
            return StreamPlaybackThreshold.minimumHeadBytesForMKV
        }
        return StreamPlaybackThreshold.minimumHeadBytes
    }

    /// Contiguous verified pieces walking backward from EOF (bridges gaps only when inner pieces arrive).
    private struct VerifiedTailAccumulation {
        let buffer: Data
        let bufferStartMediaOffset: Int64
    }

    private struct MoovTailHit {
        let buffer: Data
        let moovBaseMediaOffset: Int64
    }

    private func readAccumulatedVerifiedTailFromEOF(
        pieceStore: PieceStore,
        target: TorrentStreamTarget,
        metadata: TorrentMetadata
    ) async -> VerifiedTailAccumulation? {
        let lastPiece = min(target.lastPieceIndex, metadata.pieceCount - 1)
        guard await pieceStore.hasPiece(lastPiece) else { return nil }

        let tailIndices = StreamTailPlanner.tailPieceIndicesForDownload(
            target: target,
            pieceLength: metadata.pieceLength,
            pieceCount: metadata.pieceCount
        )
        guard let tailMin = tailIndices.min() else { return nil }
        let tailSet = Set(tailIndices)

        let fileEnd = target.byteOffset + target.byteLength
        var buffer = Data()
        var lowestPiece = lastPiece
        var piece = lastPiece

        while piece >= tailMin, tailSet.contains(piece) {
            guard await pieceStore.hasPiece(piece) else { break }
            let pieceStart = Int64(piece) * metadata.pieceLength
            let pieceEnd = pieceStart + pieceByteLength(pieceIndex: piece, metadata: metadata)
            let readStart = max(pieceStart, target.byteOffset)
            let readEnd = min(pieceEnd, fileEnd)
            guard readEnd > readStart,
                  let chunk = try? await pieceStore.read(offset: readStart, length: Int(readEnd - readStart))
            else { break }
            buffer = chunk + buffer
            lowestPiece = piece
            if piece == tailMin { break }
            piece -= 1
        }

        guard !buffer.isEmpty else { return nil }
        let bufferStartTorrent = max(target.byteOffset, Int64(lowestPiece) * metadata.pieceLength)
        let bufferStartMediaOffset = bufferStartTorrent - target.byteOffset
        return VerifiedTailAccumulation(buffer: buffer, bufferStartMediaOffset: bufferStartMediaOffset)
    }

    private func pieceByteLength(pieceIndex: Int, metadata: TorrentMetadata) -> Int64 {
        if pieceIndex == metadata.pieceCount - 1 {
            return metadata.totalSize - Int64(pieceIndex) * metadata.pieceLength
        }
        return metadata.pieceLength
    }

    private func readTailPieceChunk(
        pieceIndex: Int,
        pieceStore: PieceStore,
        target: TorrentStreamTarget,
        metadata: TorrentMetadata
    ) async -> Data? {
        let fileEnd = target.byteOffset + target.byteLength
        let pieceStart = Int64(pieceIndex) * metadata.pieceLength
        let pieceEnd = pieceStart + pieceByteLength(pieceIndex: pieceIndex, metadata: metadata)
        let readStart = max(pieceStart, target.byteOffset)
        let readEnd = min(pieceEnd, fileEnd)
        guard readEnd > readStart else { return nil }
        return try? await pieceStore.read(offset: readStart, length: Int(readEnd - readStart))
    }

    /// Scan each verified tail piece (and consecutive lower neighbors) for a complete `moov`.
    private func findCompleteMoovInVerifiedTailPieces(
        pieceStore: PieceStore,
        target: TorrentStreamTarget,
        metadata: TorrentMetadata
    ) async -> MoovTailHit? {
        let lastPiece = min(target.lastPieceIndex, metadata.pieceCount - 1)
        let tailIndices = StreamTailPlanner.tailPieceIndicesForDownload(
            target: target,
            pieceLength: metadata.pieceLength,
            pieceCount: metadata.pieceCount
        )
        let tailSet = Set(tailIndices)

        for index in tailIndices.sorted(by: >) {
            guard await pieceStore.hasPiece(index) else { continue }
            guard var buffer = await readTailPieceChunk(
                pieceIndex: index,
                pieceStore: pieceStore,
                target: target,
                metadata: metadata
            ) else { continue }

            var lowestPiece = index
            let endsAtEOF = index == lastPiece
            var probe = await probeMoovTailOffMainActor(tailData: buffer, endsAtFileEOF: endsAtEOF)
            if probe == .complete, findMoovRange(in: buffer) != nil {
                let bufferStartTorrent = max(target.byteOffset, Int64(lowestPiece) * metadata.pieceLength)
                let moovBase = bufferStartTorrent - target.byteOffset
                return MoovTailHit(buffer: buffer, moovBaseMediaOffset: moovBase)
            }

            var piece = index - 1
            while tailSet.contains(piece), await pieceStore.hasPiece(piece) {
                guard let lower = await readTailPieceChunk(
                    pieceIndex: piece,
                    pieceStore: pieceStore,
                    target: target,
                    metadata: metadata
                ) else { break }
                buffer = lower + buffer
                lowestPiece = piece
                probe = await probeMoovTailOffMainActor(tailData: buffer, endsAtFileEOF: index == lastPiece)
                if probe == .complete, let moovRange = findMoovRange(in: buffer) {
                    let bufferStartTorrent = max(target.byteOffset, Int64(lowestPiece) * metadata.pieceLength)
                    let moovBase = bufferStartTorrent - target.byteOffset
                    return MoovTailHit(buffer: buffer, moovBaseMediaOffset: moovBase)
                }
                piece -= 1
            }

            var upward = buffer
            var probeUp = probe
            var p = index + 1
            while tailSet.contains(p), await pieceStore.hasPiece(p) {
                guard let upper = await readTailPieceChunk(
                    pieceIndex: p,
                    pieceStore: pieceStore,
                    target: target,
                    metadata: metadata
                ) else { break }
                upward = upward + upper
                probeUp = await probeMoovTailOffMainActor(tailData: upward, endsAtFileEOF: p == lastPiece)
                if probeUp == .complete, findMoovRange(in: upward) != nil {
                    let bufferStartTorrent = max(target.byteOffset, Int64(lowestPiece) * metadata.pieceLength)
                    let moovBase = bufferStartTorrent - target.byteOffset
                    return MoovTailHit(buffer: upward, moovBaseMediaOffset: moovBase)
                }
                p += 1
            }
        }
        return nil
    }

    private func resolveCachedMoovHit(
        pieceStore: PieceStore,
        target: TorrentStreamTarget,
        metadata: TorrentMetadata,
        tailVerifiedCount: Int
    ) async -> MoovTailHit? {
        if moovScanVerifiedCount == tailVerifiedCount, let cachedMoovHit {
            return cachedMoovHit
        }
        let hit = await findCompleteMoovInVerifiedTailPieces(
            pieceStore: pieceStore,
            target: target,
            metadata: metadata
        )
        moovScanVerifiedCount = tailVerifiedCount
        cachedMoovHit = hit
        if hit == nil, let anchor = await findMoovAnchorPiece(
            pieceStore: pieceStore,
            target: target,
            metadata: metadata
        ) {
            await pieceManager?.setMoovAnchorPiece(UInt32(anchor))
        }
        return hit
    }

    private func findMoovAnchorPiece(
        pieceStore: PieceStore,
        target: TorrentStreamTarget,
        metadata: TorrentMetadata
    ) async -> Int? {
        let lastPiece = min(target.lastPieceIndex, metadata.pieceCount - 1)
        let tailIndices = StreamTailPlanner.tailPieceIndicesForDownload(
            target: target,
            pieceLength: metadata.pieceLength,
            pieceCount: metadata.pieceCount
        )
        for index in tailIndices.sorted(by: >) {
            guard await pieceStore.hasPiece(index) else { continue }
            guard let data = await readTailPieceChunk(
                pieceIndex: index,
                pieceStore: pieceStore,
                target: target,
                metadata: metadata
            ) else { continue }
            let probe = await probeMoovTailOffMainActor(
                tailData: data,
                endsAtFileEOF: index == lastPiece
            )
            if probe != .notFound {
                return index
            }
        }
        _ = lastPiece
        return nil
    }

    private func logVerifiedTailMoovScan(
        pieceStore: PieceStore,
        target: TorrentStreamTarget,
        metadata: TorrentMetadata,
        lastPiece: Int,
        tailVerifiedCount: Int
    ) async {
        guard moovScanLogVerifiedCount != tailVerifiedCount else { return }
        moovScanLogVerifiedCount = tailVerifiedCount

        let tailIndices = StreamTailPlanner.tailPieceIndicesForDownload(
            target: target,
            pieceLength: metadata.pieceLength,
            pieceCount: metadata.pieceCount
        )
        var lines: [String] = []
        for index in tailIndices.sorted() {
            guard await pieceStore.hasPiece(index) else { continue }
            guard let data = await readTailPieceChunk(
                pieceIndex: index,
                pieceStore: pieceStore,
                target: target,
                metadata: metadata
            ) else { continue }
            let probe = await probeMoovTailOffMainActor(
                tailData: data,
                endsAtFileEOF: index == lastPiece
            )
            lines.append("p\(index)=\(probe)(\(data.count)B)")
        }
        TorrentLog.info(
            "[Streaming] MP4 per-piece moov scan (\(tailVerifiedCount) verified): \(lines.joined(separator: ", "))"
        )
        DebugSessionLog.event(
            "per_piece_moov_scan",
            location: "StreamingOrchestrator.logVerifiedTailMoovScan",
            data: ["pieces": lines.joined(separator: ","), "verifiedCount": tailVerifiedCount]
        )
    }

    private func applyMP4TailDownloadAnchorsIfNeeded(
        pieceStore: PieceStore,
        target: TorrentStreamTarget,
        metadata: TorrentMetadata
    ) async {
        guard !moovEstimateAnchorApplied else { return }
        moovEstimateAnchorApplied = true

        if let moovOffset = await estimatedMoovMediaOffset(
            pieceStore: pieceStore,
            target: target,
            metadata: metadata
        ) {
            let firstPiece = max(0, Int(moovOffset / metadata.pieceLength))
            let lastPieceIndex = min(
                metadata.pieceCount - 1,
                Int((moovOffset + 8 * 1024 * 1024) / metadata.pieceLength)
            )
            let anchorPieces = (firstPiece...lastPieceIndex).map { UInt32($0) }
            await pieceManager?.setMoovAnchorPieces(anchorPieces)
            TorrentLog.info(
                "[Streaming] moov estimate \(moovOffset) → prioritize pieces \(firstPiece)...\(lastPieceIndex)"
            )
            DebugSessionLog.event(
                "moov_estimate_anchor",
                location: "StreamingOrchestrator.applyMP4TailDownloadAnchorsIfNeeded",
                data: [
                    "moovMediaOffset": moovOffset,
                    "firstPiece": firstPiece,
                    "lastPiece": lastPieceIndex,
                ]
            )
            return
        }

        guard let manager = pieceManager else { return }
        let interior = await manager.interiorTailPieceIndices()
        guard !interior.isEmpty else { return }
        await manager.setMoovAnchorPieces(interior)
        TorrentLog.info(
            "[Streaming] moov estimate unavailable → interior tail pieces (\(interior.count) pieces, last=\(interior.first ?? 0))"
        )
        DebugSessionLog.event(
            "interior_tail_anchor",
            location: "StreamingOrchestrator.applyMP4TailDownloadAnchorsIfNeeded",
            data: [
                "pieceCount": interior.count,
                "highestPiece": interior.first ?? 0,
                "lowestPiece": interior.last ?? 0,
            ]
        )
    }

    private func estimatedMoovMediaOffset(
        pieceStore: PieceStore,
        target: TorrentStreamTarget,
        metadata: TorrentMetadata
    ) async -> Int64? {
        guard let headData = try? await pieceStore.read(offset: target.byteOffset, length: 512) else {
            return nil
        }
        guard let mdatBoxOffset = mdatBoxOffsetInMediaFile(headData: headData) else { return nil }
        guard let mdatHeader = try? await pieceStore.read(
            offset: target.byteOffset + mdatBoxOffset,
            length: 16
        ) else { return nil }
        guard let mdatEnd = mdatBoxEndMediaOffset(
            mdatHeader: mdatHeader,
            mdatBoxOffset: mdatBoxOffset,
            fileLength: target.byteLength
        ) else { return nil }
        guard mdatEnd > mdatBoxOffset else { return nil }
        if mdatEnd >= target.byteLength {
            // mdat size 0 → extends to EOF; moov is still inside the tail byte span.
            let tailSpan = StreamTailPlanner.tailByteSpan(
                byteLength: target.byteLength,
                pieceLength: metadata.pieceLength
            )
            return max(mdatBoxOffset + 8, target.byteLength - tailSpan)
        }
        guard mdatEnd <= target.byteLength else { return nil }
        return mdatEnd
    }

    private func mdatBoxOffsetInMediaFile(headData: Data) -> Int64? {
        guard let ftyp = extractFtypBox(from: headData) else { return nil }
        var offset = ftyp.count
        while offset + 8 <= headData.count {
            let size32 = headData.readUInt32BE(at: offset)
            let type = String(data: headData[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
            if type == "mdat" { return Int64(offset) }
            let boxSize: Int
            if size32 == 1 {
                guard offset + 16 <= headData.count else { return nil }
                let large = headData.readUInt64BE(at: offset + 8)
                guard large >= 16, large <= UInt64(Int.max) else { return nil }
                boxSize = Int(large)
            } else if size32 < 8 {
                return nil
            } else {
                boxSize = Int(size32)
            }
            guard offset + boxSize <= headData.count else { return nil }
            offset += boxSize
        }
        return nil
    }

    private func mdatBoxEndMediaOffset(
        mdatHeader: Data,
        mdatBoxOffset: Int64,
        fileLength: Int64
    ) -> Int64? {
        guard mdatHeader.count >= 8 else { return nil }
        let type = String(data: mdatHeader[(mdatHeader.startIndex + 4)..<(mdatHeader.startIndex + 8)], encoding: .ascii) ?? ""
        guard type == "mdat" else { return nil }
        let size32 = mdatHeader.readUInt32BE(at: mdatHeader.startIndex)
        if size32 == 1 {
            guard mdatHeader.count >= 16 else { return nil }
            let large = mdatHeader.readUInt64BE(at: mdatHeader.startIndex + 8)
            return mdatBoxOffset + Int64(large)
        }
        if size32 == 0 {
            return fileLength
        }
        guard size32 >= 8 else { return nil }
        return mdatBoxOffset + Int64(size32)
    }

    private func tryRemuxFromEstimatedMoovOffset(
        pieceStore: PieceStore,
        target: TorrentStreamTarget,
        metadata: TorrentMetadata
    ) async -> MP4FastStartRemuxer.RemuxedLayout? {
        guard let moovOffset = await estimatedMoovMediaOffset(
            pieceStore: pieceStore,
            target: target,
            metadata: metadata
        ) else {
            return nil
        }
        let maxRead = min(Int64(32 * 1024 * 1024), target.byteLength - moovOffset)
        guard maxRead >= 8 else { return nil }

        let torrentOffset = target.byteOffset + moovOffset
        let readable = await pieceStore.readableLength(offset: torrentOffset, length: Int(maxRead))
        guard readable >= 8 else {
            TorrentLog.debug(
                "[Streaming] estimated moov @ \(moovOffset) — only \(readable)B readable (need moov piece)"
            )
            return nil
        }

        guard let moovBuffer = try? await pieceStore.read(offset: torrentOffset, length: readable) else {
            return nil
        }
        let endsAtEOF = moovOffset + Int64(readable) >= target.byteLength
        let probe = await probeMoovTailOffMainActor(tailData: moovBuffer, endsAtFileEOF: endsAtEOF)
        guard probe == .complete, let moovRange = findMoovRange(in: moovBuffer) else {
            TorrentLog.debug(
                "[Streaming] estimated moov @ \(moovOffset) probe=\(probe) readable=\(readable)B"
            )
            return nil
        }

        let moovData = Data(moovBuffer[moovRange])
        let moovOffsetInMediaFile = moovOffset + Int64(moovRange.lowerBound - moovBuffer.startIndex)

        var ftyp: Data?
        if let headData = try? await pieceStore.read(offset: target.byteOffset, length: 64) {
            ftyp = extractFtypBox(from: headData)
        }
        let ftypLen = Int64(ftyp?.count ?? 0)
        let mdatBoxOffsetInMediaFile = ftypLen

        var mdatContentLength: Int64 = 0
        if let mdatHeader = try? await pieceStore.read(offset: target.byteOffset + mdatBoxOffsetInMediaFile, length: 16) {
            mdatContentLength = parseMdatContentLength(
                from: mdatHeader,
                mdatBoxOffsetInMediaFile: mdatBoxOffsetInMediaFile,
                moovOffsetInMediaFile: moovOffsetInMediaFile
            )
        }
        if mdatContentLength <= 0 {
            mdatContentLength = moovOffsetInMediaFile - (mdatBoxOffsetInMediaFile + 8)
        }
        guard mdatContentLength > 0 else { return nil }

        TorrentLog.info(
            "[Streaming] remux from estimated moov @ \(moovOffsetInMediaFile) (\(moovData.count)B, readable \(readable)B)"
        )
        return MP4FastStartRemuxer.buildLayout(
            moovData: moovData,
            ftypData: ftyp,
            originalFileLength: target.byteLength,
            originalMoovOffset: moovOffsetInMediaFile,
            mdatOffset: mdatBoxOffsetInMediaFile,
            mdatLength: mdatContentLength
        )
    }

    private func readVerifiedTailWindow(
        pieceStore: PieceStore,
        target: TorrentStreamTarget,
        metadata: TorrentMetadata
    ) async -> (data: Data, fileOffset: Int64)? {
        let tailSpan = StreamTailPlanner.maxTailByteSpan
        let fileEnd = target.byteOffset + target.byteLength
        let tailStart = max(target.byteOffset, fileEnd - tailSpan)
        let spanLength = Int(fileEnd - tailStart)
        guard spanLength >= 16 else { return nil }

        guard let readable = await pieceStore.readableSpan(
            offset: tailStart,
            length: spanLength,
            preferSuffix: true
        ) else {
            return nil
        }

        TorrentLog.debug(
            "[Streaming] readVerifiedTailWindow: reading \(readable.length / 1024)KB from offset \(readable.offset) (suffix within tail span)"
        )
        guard let data = try? await pieceStore.read(offset: readable.offset, length: readable.length) else {
            return nil
        }
        return (data, readable.offset)
    }


    // MARK: - Fast-start remux watcher

    private func startFastStartWatcher(target: TorrentStreamTarget, metadata: TorrentMetadata) {
        fastStartWatcherTask?.cancel()
        // MKV / WebM and fast-start MP4 don't benefit from moov-remux — leave them alone.
        guard target.needsMP4MoovTailProbe else { return }
        guard let store = pieceStore else { return }

        fastStartWatcherTask = Task { [weak self] in
            // Poll for moov readiness from contiguous verified tail pieces.
            // The PiecePrioritizer already prefers tail pieces first, so this
            // typically resolves within a handful of pieces — not the entire
            // 8–32 MB tail span.
            while !Task.isCancelled {
                guard let self else { return }
                if await self.rangeServerHasRemux() { return }
                var layout = await self.tryRemuxFromEstimatedMoovOffset(
                    pieceStore: store,
                    target: target,
                    metadata: metadata
                )
                if layout == nil {
                    layout = await self.attemptFastStartRemux(
                        pieceStore: store,
                        target: target,
                        metadata: metadata
                    )
                }
                if let layout {
                    await self.installRemuxLayout(layout)
                    return
                }
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    private func probeMoovTailOffMainActor(
        tailData: Data,
        endsAtFileEOF: Bool
    ) async -> StreamTailPlanner.MoovTailProbeResult {
        await Task.detached(priority: .utility) {
            StreamTailPlanner.moovTailProbe(in: tailData, endsAtFileEOF: endsAtFileEOF)
        }.value
    }

    private func probeMKVSeekTableOffMainActor(tailData: Data) async -> StreamTailPlanner.MKVSeekTableProbeResult {
        await Task.detached(priority: .utility) {
            StreamTailPlanner.mkvSeekTableProbe(in: tailData)
        }.value
    }

    private func analyzeMKVCuesOffMainActor(
        tailData: Data,
        segmentBodyOffset: Int64
    ) async -> StreamTailPlanner.MKVCuesAnalysis? {
        await Task.detached(priority: .utility) {
            StreamTailPlanner.analyzeMKVCues(in: tailData, segmentBodyOffset: segmentBodyOffset)
        }.value
    }

    private func rangeServerHasRemux() async -> Bool {
        rangeServer.remuxedLayout != nil
    }

    private func installRemuxLayout(_ layout: MP4FastStartRemuxer.RemuxedLayout) async {
        rangeServer.setRemuxedLayout(layout)
        tailReadyCached = true
        tailReadyCachedAt = ContinuousClock.now
        TorrentLog.info(
            "[Streaming] Fast-start remux ready — virtual header \(layout.syntheticHeader.count)B virtualLength=\(layout.virtualFileLength)"
        )
        DebugSessionLog.event(
            "remux_installed",
            location: "StreamingOrchestrator.installRemuxLayout",
            data: ["virtualLength": layout.virtualFileLength]
        )
    }

    private func attemptFastStartRemux(
        pieceStore: PieceStore,
        target: TorrentStreamTarget,
        metadata: TorrentMetadata
    ) async -> MP4FastStartRemuxer.RemuxedLayout? {
        // Need the last piece (which contains the moov's end in non-faststart MP4s).
        let lastPiece = min(target.lastPieceIndex, metadata.pieceCount - 1)
        guard await pieceStore.hasPiece(lastPiece) else { return nil }

        let tailData: Data
        let moovBaseMediaOffset: Int64
        let tailVerifiedCount = await streamTailPiecesVerified()
        if let moovHit = await resolveCachedMoovHit(
            pieceStore: pieceStore,
            target: target,
            metadata: metadata,
            tailVerifiedCount: tailVerifiedCount
        ) {
            tailData = moovHit.buffer
            moovBaseMediaOffset = moovHit.moovBaseMediaOffset
        } else if let accumulated = await readAccumulatedVerifiedTailFromEOF(
            pieceStore: pieceStore,
            target: target,
            metadata: metadata
        ),
           await probeMoovTailOffMainActor(tailData: accumulated.buffer, endsAtFileEOF: true) == .complete {
            tailData = accumulated.buffer
            moovBaseMediaOffset = accumulated.bufferStartMediaOffset
        } else if let (suffixData, suffixOffset) = await readVerifiedTailWindow(
            pieceStore: pieceStore,
            target: target,
            metadata: metadata
        ),
           await probeMoovTailOffMainActor(tailData: suffixData, endsAtFileEOF: true) == .complete {
            tailData = suffixData
            moovBaseMediaOffset = suffixOffset - target.byteOffset
        } else {
            return nil
        }

        guard let moovRange = findMoovRange(in: tailData) else { return nil }
        let moovData = Data(tailData[moovRange])

        // Read ftyp from the file head (first 64 bytes is plenty; ftyp is usually 24–32 bytes).
        var ftyp: Data?
        if let headData = try? await pieceStore.read(offset: target.byteOffset, length: 64) {
            ftyp = extractFtypBox(from: headData)
        }

        let moovOffsetInMediaFile = moovBaseMediaOffset + Int64(moovRange.lowerBound - tailData.startIndex)

        // In a non-fast-start MP4, layout is: [ftyp][mdat-box][...][moov].
        // mdat box header begins right after ftyp.
        let ftypLen = Int64(ftyp?.count ?? 0)
        let mdatBoxOffsetInMediaFile = ftypLen

        // The mdat box header is 8 (or 16) bytes; we need mdat content length.
        // Read the mdat box header to determine its actual size.
        var mdatContentLength: Int64 = 0
        if let mdatHeader = try? await pieceStore.read(offset: target.byteOffset + mdatBoxOffsetInMediaFile, length: 16) {
            mdatContentLength = parseMdatContentLength(from: mdatHeader, mdatBoxOffsetInMediaFile: mdatBoxOffsetInMediaFile, moovOffsetInMediaFile: moovOffsetInMediaFile)
        }
        if mdatContentLength <= 0 {
            // Fall back: assume one contiguous mdat from after ftyp up to the moov box.
            mdatContentLength = moovOffsetInMediaFile - (mdatBoxOffsetInMediaFile + 8)
        }
        guard mdatContentLength > 0 else { return nil }

        return MP4FastStartRemuxer.buildLayout(
            moovData: moovData,
            ftypData: ftyp,
            originalFileLength: target.byteLength,
            originalMoovOffset: moovOffsetInMediaFile,
            mdatOffset: mdatBoxOffsetInMediaFile,
            mdatLength: mdatContentLength
        )
    }

    private func parseMdatContentLength(
        from headerBytes: Data,
        mdatBoxOffsetInMediaFile: Int64,
        moovOffsetInMediaFile: Int64
    ) -> Int64 {
        guard headerBytes.count >= 8 else { return 0 }
        let typeBytes = headerBytes[(headerBytes.startIndex + 4)..<(headerBytes.startIndex + 8)]
        let type = String(data: Data(typeBytes), encoding: .ascii) ?? ""
        guard type == "mdat" else { return 0 }

        let size32 = headerBytes.withUnsafeBytes { ptr -> UInt32 in
            UInt32(bigEndian: ptr.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        }
        if size32 == 0 {
            // Box extends to EOF (rare in non-fast-start MP4). Assume mdat ends right before moov.
            return moovOffsetInMediaFile - (mdatBoxOffsetInMediaFile + 8)
        }
        if size32 == 1, headerBytes.count >= 16 {
            let large = headerBytes.withUnsafeBytes { ptr -> UInt64 in
                UInt64(bigEndian: ptr.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
            }
            return Int64(large) - 16
        }
        return Int64(size32) - 8
    }

    /// Locate the moov box (size+type header) within a tail buffer.
    private func findMoovRange(in data: Data) -> Range<Data.Index>? {
        guard data.count >= 8 else { return nil }
        var i = data.endIndex - 8
        while i >= data.startIndex {
            let typeStart = i + 4
            if data[typeStart] == 0x6D /* m */,
               data[typeStart + 1] == 0x6F /* o */,
               data[typeStart + 2] == 0x6F /* o */,
               data[typeStart + 3] == 0x76 /* v */ {
                let size32 = data.withUnsafeBytes { ptr -> UInt32 in
                    UInt32(bigEndian: ptr.loadUnaligned(fromByteOffset: i - data.startIndex, as: UInt32.self))
                }
                var size = Int(size32)
                var headerLen = 8
                if size32 == 1, i + 16 <= data.endIndex {
                    let large = data.withUnsafeBytes { ptr -> UInt64 in
                        UInt64(bigEndian: ptr.loadUnaligned(fromByteOffset: i + 8 - data.startIndex, as: UInt64.self))
                    }
                    size = Int(large)
                    headerLen = 16
                }
                if size >= headerLen, i + size <= data.endIndex {
                    return i..<(i + size)
                }
            }
            i -= 1
        }
        return nil
    }

    /// Pull the ftyp box out of the file head (typically the first 8–32 bytes).
    private func extractFtypBox(from data: Data) -> Data? {
        guard data.count >= 8 else { return nil }
        let typeBytes = data[(data.startIndex + 4)..<(data.startIndex + 8)]
        let type = String(data: Data(typeBytes), encoding: .ascii) ?? ""
        guard type == "ftyp" else { return nil }
        let size = data.withUnsafeBytes { ptr -> UInt32 in
            UInt32(bigEndian: ptr.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        }
        let sizeInt = Int(size)
        guard sizeInt >= 8, sizeInt <= data.count else { return nil }
        return Data(data[data.startIndex..<(data.startIndex + sizeInt)])
    }

    public func streamTailPieceCount() async -> Int {
        guard let target = streamTarget, let metadata else { return 0 }
        return StreamTailPlanner.tailPieceIndicesForDownload(
            target: target,
            pieceLength: metadata.pieceLength,
            pieceCount: metadata.pieceCount
        ).count
    }

    public func streamTailPiecesVerified() async -> Int {
        guard let pieceStore, let target = streamTarget, let metadata else { return 0 }
        let indices = StreamTailPlanner.tailPieceIndicesForDownload(
            target: target,
            pieceLength: metadata.pieceLength,
            pieceCount: metadata.pieceCount
        )
        var count = 0
        for index in indices where await pieceStore.hasPiece(index) {
            count += 1
        }
        return count
     }

     public func streamTailPiecesProgress() async -> Double {
         guard let pieceManager, let target = streamTarget, let metadata else { return 0 }
         let indices = StreamTailPlanner.tailPieceIndicesForDownload(
             target: target,
             pieceLength: metadata.pieceLength,
             pieceCount: metadata.pieceCount
         )
         guard !indices.isEmpty else { return 1.0 }
         
         var totalProgress: Double = 0.0
         for index in indices {
             let p = await pieceManager.pieceProgress(pieceIndex: UInt32(index))
             totalProgress += p
         }
         return totalProgress / Double(indices.count)
     }

     public func streamTargetNeedsTailProbe() async -> Bool {
        streamTarget?.needsTailProbeForPlayback ?? false
    }

    public func streamIndexProbeLabel() async -> String {
        guard let target = streamTarget else { return "file index" }
        if target.needsMP4MoovTailProbe { return "MP4 index (moov)" }
        let ext = (target.file.relativePath as NSString).pathExtension.lowercased()
        if ext == "mkv" || ext == "webm" || target.contentType.contains("matroska") {
            return "MKV index (cues)"
        }
        return "file index"
    }

    public func downloadSpeed() async -> Double {
        torrentEngine?.downloadSpeed ?? 0
    }

    public func peerCount() async -> Int {
        torrentEngine?.livePeerCount() ?? 0
    }

    public func transferringPeerCount() async -> Int {
        torrentEngine?.transferringPeerCount() ?? 0
    }

    public func peerSocketCount() async -> Int {
        torrentEngine?.peerSocketCount() ?? 0
    }

    public func diagnosticsSnapshot(
        torrent: TorrentResult?,
        sessionState: StreamSession<StreamingOrchestrator>.State,
        swarmSeeders: Int,
        swarmLeechers: Int,
        livePeerCount: Int,
        liveDownloadSpeed: Double,
        liveBufferedBytes: Int64,
        liveBufferedPieces: Int,
        streamURL: URL?
    ) async -> StreamDiagnosticsSnapshot {
        var sections: [StreamDiagnosticsSnapshot.Section] = []

        sections.append(
            StreamDiagnosticsSnapshot.Section(
                title: "Session",
                rows: Self.sessionRows(
                    torrent: torrent,
                    sessionState: sessionState,
                    swarmSeeders: swarmSeeders,
                    swarmLeechers: swarmLeechers,
                    livePeerCount: livePeerCount,
                    liveDownloadSpeed: liveDownloadSpeed,
                    liveBufferedBytes: liveBufferedBytes,
                    liveBufferedPieces: liveBufferedPieces,
                    streamURL: streamURL
                )
            )
        )

        if let torrent {
            sections.append(StreamDiagnosticsSnapshot.Section(title: "Release", rows: Self.releaseRows(torrent: torrent)))
        }

        if let metadata {
            sections.append(StreamDiagnosticsSnapshot.Section(title: "Torrent", rows: Self.torrentRows(metadata: metadata)))
        }

        if let target = streamTarget {
            let tailReady = await isStreamTailPieceReady()
            let tailTotal = await streamTailPieceCount()
            let tailVerified = await streamTailPiecesVerified()
            sections.append(
                StreamDiagnosticsSnapshot.Section(
                    title: "Stream file",
                    rows: Self.streamTargetRows(
                        target: target,
                        tailReady: tailReady,
                        tailVerified: tailVerified,
                        tailTotal: tailTotal
                    )
                )
            )
        }

        if pieceStore != nil || pieceManager != nil {
            sections.append(StreamDiagnosticsSnapshot.Section(title: "Buffer", rows: await bufferRows()))
        }

        if let engine = torrentEngine {
            sections.append(
                StreamDiagnosticsSnapshot.Section(title: "Peers & trackers", rows: engine.peerDiagnosticRows())
            )
        }

        if rangeServer.port > 0 || rangeServer.isRunning {
            sections.append(
                StreamDiagnosticsSnapshot.Section(title: "HTTP range server", rows: Self.rangeServerRows(rangeServer))
            )
        }

        return StreamDiagnosticsSnapshot(sections: sections)
    }

    private static func sessionRows(
        torrent: TorrentResult?,
        sessionState: StreamSession<StreamingOrchestrator>.State,
        swarmSeeders: Int,
        swarmLeechers: Int,
        livePeerCount: Int,
        liveDownloadSpeed: Double,
        liveBufferedBytes: Int64,
        liveBufferedPieces: Int,
        streamURL: URL?
    ) -> [StreamDiagnosticsSnapshot.Row] {
        let stateText: String = switch sessionState {
        case .idle: "Idle"
        case .preparing: "Preparing"
        case .buffering(let p): "Buffering (\(Int(p * 100))%)"
        case .ready: "Ready"
        case .failed(let e): "Failed — \(e)"
        case .cancelled: "Cancelled"
        }

        var rows: [StreamDiagnosticsSnapshot.Row] = [
            .init(label: "State", value: stateText),
            .init(label: "Live peers", value: "\(livePeerCount)"),
            .init(label: "Indexer seeders (scrape)", value: "\(swarmSeeders)"),
            .init(label: "Indexer leechers", value: "\(swarmLeechers)"),
            .init(label: "Download speed", value: StreamDiagnosticsFormatting.speed(liveDownloadSpeed)),
            .init(label: "Head buffered", value: StreamDiagnosticsFormatting.bytes(liveBufferedBytes)),
            .init(label: "Verified head pieces", value: "\(liveBufferedPieces)"),
        ]

        if let streamURL {
            rows.append(.init(label: "Local stream URL", value: MovieBoxFileLogger.redactURL(streamURL)))
        }
        if torrent == nil {
            rows.append(.init(label: "Source", value: "No active torrent session"))
        }

        return rows
    }

    private static func releaseRows(torrent: TorrentResult) -> [StreamDiagnosticsSnapshot.Row] {
        var rows: [StreamDiagnosticsSnapshot.Row] = [
            .init(label: "Title", value: torrent.title),
            .init(label: "Quality", value: torrent.quality.rawValue),
            .init(label: "Codec", value: torrent.codec.rawValue),
            .init(label: "Source", value: torrent.source.rawValue),
            .init(label: "Language", value: torrent.language),
            .init(label: "Size", value: StreamDiagnosticsFormatting.bytes(torrent.sizeBytes)),
        ]
        if let hdr = torrent.hdrType {
            rows.append(.init(label: "HDR", value: hdr.rawValue))
        }
        if let audio = torrent.audioFormat {
            rows.append(.init(label: "Audio", value: audio.rawValue))
        }
        if let hash = torrent.infoHash {
            rows.append(.init(label: "Info hash", value: "\(hash.prefix(8))…\(hash.suffix(8))"))
        }
        return rows
    }

    private static func torrentRows(metadata: TorrentMetadata) -> [StreamDiagnosticsSnapshot.Row] {
        [
            .init(label: "Name", value: metadata.name),
            .init(label: "Info hash", value: "\(metadata.infoHash.prefix(8))…"),
            .init(label: "Total size", value: StreamDiagnosticsFormatting.bytes(metadata.totalSize)),
            .init(label: "Piece length", value: StreamDiagnosticsFormatting.bytes(metadata.pieceLength)),
            .init(label: "Piece count", value: "\(metadata.pieceCount)"),
            .init(label: "Files", value: "\(metadata.files.count)"),
            .init(label: "Trackers", value: "\(metadata.trackers.count)"),
        ]
    }

    private static func streamTargetRows(
        target: TorrentStreamTarget,
        tailReady: Bool,
        tailVerified: Int = 0,
        tailTotal: Int = 0
    ) -> [StreamDiagnosticsSnapshot.Row] {
        var tailValue = target.needsTailProbeForPlayback ? (tailReady ? "Ready" : "Waiting") : "Not required"
        if tailTotal > 0, target.needsTailProbeForPlayback {
            tailValue += " (\(tailVerified)/\(tailTotal) pieces)"
        }
        return [
            .init(label: "File", value: target.file.relativePath),
            .init(label: "MIME", value: target.contentType),
            .init(label: "Media bytes", value: StreamDiagnosticsFormatting.bytes(target.byteLength)),
            .init(label: "Byte offset", value: "\(target.byteOffset)"),
            .init(label: "First piece", value: "\(target.firstPieceIndex)"),
            .init(label: "Last piece", value: "\(target.lastPieceIndex)"),
            .init(label: "End index", value: tailValue),
        ]
    }

    private func bufferRows() async -> [StreamDiagnosticsSnapshot.Row] {
        let storeProgress = await pieceStore?.progress() ?? 0
        let verifiedPieces = await pieceStore?.contiguousPiecesFromStart() ?? 0
        let verifiedBytes = await pieceStore?.contiguousBytesFromStreamStart() ?? 0
        let headBytes = await pieceStore?.streamHeadContiguousBytes() ?? 0
        let managerProgress = await pieceManager?.progress() ?? 0
        let verifiedCount = await pieceManager?.downloadedCount() ?? 0
        let pending = await pieceManager?.pendingRequestCount() ?? 0
        let minHead = StreamPlaybackThreshold.minimumHeadBytes

        return [
            .init(label: "Verified pieces (all)", value: "\(verifiedCount)"),
            .init(label: "Piece store progress", value: StreamDiagnosticsFormatting.percent(storeProgress)),
            .init(label: "Piece manager progress", value: StreamDiagnosticsFormatting.percent(managerProgress)),
            .init(label: "Contiguous from stream start", value: "\(verifiedPieces) piece(s)"),
            .init(label: "Verified stream bytes", value: StreamDiagnosticsFormatting.bytes(verifiedBytes)),
            .init(label: "Head contiguous (incl. in-flight)", value: StreamDiagnosticsFormatting.bytes(headBytes)),
            .init(
                label: "Playback head threshold",
                value: "\(StreamDiagnosticsFormatting.bytes(minHead)) (\(headBytes >= minHead ? "met" : "pending"))"
            ),
            .init(label: "Pending block requests", value: "\(pending)"),
        ]
    }

    private static func rangeServerRows(_ server: HTTPRangeServer) -> [StreamDiagnosticsSnapshot.Row] {
        [
            .init(label: "Listening", value: server.isRunning ? "Yes" : "No"),
            .init(label: "Port", value: server.port > 0 ? "\(server.port)" : "—"),
            .init(label: "Max range response", value: StreamDiagnosticsFormatting.bytes(2 * 1024 * 1024)),
        ]
    }
}

public enum StreamingOrchestratorError: Error, LocalizedError {
    case invalidMagnetURI
    case failedToInitialize
    case metadataUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidMagnetURI: "Invalid magnet URI"
        case .failedToInitialize: "Failed to initialize streaming orchestrator"
        case .metadataUnavailable(let message): message
        }
    }
}

// MARK: - Torrent Engine

@MainActor
public final class TorrentEngine {
    public private(set) var downloadSpeed: Double = 0
    public private(set) var activePeerCount: Int = 0

    private let metadata: TorrentMetadata
    private let pieceManager: PieceManager
    private let pieceStore: PieceStore
    private let peerId: String
    private let progressHandler: @Sendable (Double, Double, Int) -> Void

    private var trackerClient = TrackerClient()
    private var udpTrackerClient = UDPTrackerClient()
    private var dht: KademliaDHT?
    private var peerConnections: [PeerConnection] = []
    private var peerConnectionTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var connectedPeerKeys = Set<String>()
    private var isRunning = false
    private var announceTimer: Task<Void, Never>?
    private var statsTimer: Task<Void, Never>?
    private var maintenanceTimer: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?

    private var bytesDownloaded: Int64 = 0
    private var recentBytesSamples: [(date: Date, bytes: Int64)] = []
    private var lastAnnounceTime = Date.distantPast

    private let maxPeerConnections = 64
    private let peersPerAnnounce = 30
    private static let announceWallTimeoutSeconds: TimeInterval = 4
    private static let maxTrackersPerRound = 40
    private static let minPeersBeforeEarlyAnnounceExit = 48

    public init(
        metadata: TorrentMetadata,
        pieceManager: PieceManager,
        pieceStore: PieceStore,
        peerId: String,
        progressHandler: @escaping @Sendable (Double, Double, Int) -> Void
    ) {
        self.metadata = metadata
        self.pieceManager = pieceManager
        self.pieceStore = pieceStore
        self.peerId = peerId
        self.progressHandler = progressHandler
    }

    public func start() async {
        guard !isRunning else { return }
        isRunning = true

        startAnnounceTimer()
        startMaintenanceTimer()

        statsTimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard isRunning else { return }
                await updateStats()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
            }
        }

        bootstrapTask = Task { [weak self] in
            await self?.bootstrapPeers()
        }
        await updateStats()
    }

    private func bootstrapPeers() async {
        await ensureDHTRunning()
        guard !Task.isCancelled else { return }
        let trackerPeers = await fetchPeersFromTrackers(event: .started)
        guard !Task.isCancelled else { return }
        await connectToPeers(trackerPeers)
        guard !Task.isCancelled else { return }

        if livePeerCount() < 5 {
            let dhtPeers = await dht?.findPeers(infoHash: metadata.infoHash) ?? []
            guard !Task.isCancelled else { return }
            await connectToPeers(dhtPeers)
        }
    }

    func livePeerCount() -> Int {
        peerConnections.filter { peer in
            switch peer.state {
            case .connecting, .handshaking, .connected, .choked, .unchoked, .downloading:
                return true
            case .disconnected, .error:
                return false
            }
        }.count
    }

    func transferringPeerCount() -> Int {
        peerConnections.filter { peer in
            switch peer.state {
            case .unchoked, .downloading:
                return true
            default:
                return false
            }
        }.count
    }

    func peerSocketCount() -> Int {
        peerConnections.count
    }

    func refreshDownloadPriorities() {
        for peer in peerConnections {
            peer.scheduleAdditionalRequests()
        }
    }

    public func stop() {
        isRunning = false
        announceTimer?.cancel()
        statsTimer?.cancel()
        maintenanceTimer?.cancel()
        bootstrapTask?.cancel()
        bootstrapTask = nil
        dht?.stop()
        dht = nil

        for (_, task) in peerConnectionTasks {
            task.cancel()
        }
        peerConnectionTasks.removeAll()
        for peer in peerConnections {
            peer.disconnect()
        }
        peerConnections.removeAll()
        connectedPeerKeys.removeAll()
    }

    private func announceToTrackers() async {
        let peers = await fetchPeersFromTrackers(event: .started)
        await connectToPeers(peers)
    }

    private func selectedTrackersForAnnounce() -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func append(_ url: String) {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return }
            ordered.append(trimmed)
        }

        for tracker in metadata.trackers where tracker.lowercased().hasPrefix("udp://") {
            append(tracker)
        }
        for tracker in metadata.trackers where tracker.lowercased().hasPrefix("http") {
            append(tracker)
        }
        for tracker in metadata.trackers {
            append(tracker)
        }

        return Array(ordered.prefix(Self.maxTrackersPerRound))
    }

    private func fetchPeersFromTrackers(event: TrackerEvent) async -> [PeerInfo] {
        let now = Date()
        let shouldAnnounceTrackers = now.timeIntervalSince(lastAnnounceTime) >= 30

        var peersFound: [PeerInfo] = []
        if shouldAnnounceTrackers {
            lastAnnounceTime = now
            let trackers = selectedTrackersForAnnounce()
            TorrentLog.info(
                "[TorrentEngine] Announcing to \(trackers.count) trackers (of \(metadata.trackers.count), \(Int(Self.announceWallTimeoutSeconds))s cap)..."
            )
            let eventCode = event.rawValue
            let deadline = Date().addingTimeInterval(Self.announceWallTimeoutSeconds)

            peersFound = await withTaskGroup(of: [PeerInfo].self) { group in
                for trackerURL in trackers {
                    group.addTask { [self] in
                        if trackerURL.hasPrefix("udp://") {
                            guard let response = try? await udpTrackerClient.announce(
                                trackerURL: trackerURL,
                                infoHash: metadata.infoHash,
                                peerId: peerId,
                                port: 6881,
                                downloaded: bytesDownloaded,
                                left: metadata.totalSize - bytesDownloaded,
                                event: TrackerEvent(rawValue: eventCode) ?? .empty
                            ) else { return [] }
                            return response.peers
                        }
                        guard let response = try? await trackerClient.announce(
                            trackerURL: trackerURL,
                            infoHash: metadata.infoHash,
                            peerId: peerId,
                            port: 6881,
                            downloaded: bytesDownloaded,
                            left: metadata.totalSize - bytesDownloaded,
                            event: TrackerEvent(rawValue: eventCode) ?? .empty
                        ) else { return [] }
                        return response.peers
                    }
                }

                var merged: [PeerInfo] = []
                var seen = Set<String>()
                while let peers = await group.next() {
                    for peer in peers {
                        let key = peerKey(peer)
                        if seen.insert(key).inserted {
                            merged.append(peer)
                        }
                    }
                    if Date() >= deadline || merged.count >= Self.minPeersBeforeEarlyAnnounceExit {
                        group.cancelAll()
                        break
                    }
                }
                return merged
            }
        } else {
            TorrentLog.info("[TorrentEngine] Throttling tracker announce. Relying on DHT discovery.")
        }

        var finalPeers = peersFound
        if finalPeers.count < Self.minPeersBeforeEarlyAnnounceExit {
            await ensureDHTRunning()
            let dhtPeers = await dht?.findPeers(infoHash: metadata.infoHash) ?? []
            for peer in dhtPeers {
                let key = peerKey(peer)
                if !connectedPeerKeys.contains(key), !finalPeers.contains(where: { peerKey($0) == key }) {
                    finalPeers.append(peer)
                }
            }
        }

        TorrentLog.info("[TorrentEngine] Found \(finalPeers.count) unique peers")
        return finalPeers
    }

    private func ensureDHTRunning() async {
        guard dht == nil else { return }
        let dht = KademliaDHT()
        self.dht = dht
        do {
            try await dht.start(port: 6882)
            await dht.announce(infoHash: metadata.infoHash, port: 6881)
        } catch {
            self.dht = nil
        }
    }

    private func startAnnounceTimer() {
        announceTimer = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    break
                }
                guard let self else { return }
                guard isRunning else { return }
                let peers = await fetchPeersFromTrackers(event: .empty)
                guard !Task.isCancelled else { return }
                await connectToPeers(peers)
            }
        }
    }

    private func startMaintenanceTimer() {
        maintenanceTimer = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    break
                }
                guard let self else { return }
                guard isRunning else { return }
                pruneDeadPeers()
                await expireStalledRequests()

                if livePeerCount() < 8 {
                    let peers = await fetchPeersFromTrackers(event: .empty)
                    guard !Task.isCancelled else { return }
                    await connectToPeers(peers)
                }
            }
        }
    }

    private func connectToPeers(_ peers: [PeerInfo]) async {
        pruneDeadPeers()

        var connected = 0
        for peerInfo in peers {
            guard isRunning else { return }
            guard peerConnections.count < maxPeerConnections else { break }

            let key = peerKey(peerInfo)
            guard connectedPeerKeys.insert(key).inserted else { continue }

            let connection = PeerConnection(peerInfo: peerInfo, connectionPeerId: peerId)
            peerConnections.append(connection)
            connected += 1

            let task = Task {
                await connection.connect(
                    infoHash: metadata.infoHash,
                    pieceManager: pieceManager,
                    onPieceReceived: { [weak self] pieceIndex, offset, block in
                        await self?.handlePieceReceived(pieceIndex: pieceIndex, offset: offset, block: block)
                    },
                    onPeersDiscovered: { [weak self] discovered in
                        await self?.handleDiscoveredPeers(discovered)
                    }
                )
            }
            peerConnectionTasks[ObjectIdentifier(connection)] = task
        }

        if connected > 0 {
            TorrentLog.info("[TorrentEngine] Connecting to \(connected) new peers (\(peerConnections.count) total)")
        }
        await updateStats()
    }

    private func handleDiscoveredPeers(_ peers: [PeerInfo]) async {
        guard isRunning else { return }
        await connectToPeers(peers)
    }

    private func pruneDeadPeers() {
        let before = peerConnections.count
        let currentCount = before
        peerConnections.removeAll { peer in
            let shouldRemove: Bool
            switch peer.state {
            case .disconnected, .error:
                connectedPeerKeys.remove(peerKey(peer.peerInfo))
                shouldRemove = true
            case .connecting, .handshaking:
                if peer.handshakeAge > 25 {
                    connectedPeerKeys.remove(peerKey(peer.peerInfo))
                    peer.disconnect()
                    shouldRemove = true
                } else {
                    shouldRemove = false
                }
            case .connected, .choked:
                if currentCount >= maxPeerConnections - 8, peer.handshakeAge > 60, peer.piecesReceived == 0 {
                    connectedPeerKeys.remove(peerKey(peer.peerInfo))
                    peer.disconnect()
                    shouldRemove = true
                } else {
                    shouldRemove = false
                }
            default:
                shouldRemove = false
            }
            if shouldRemove {
                peerConnectionTasks[ObjectIdentifier(peer)]?.cancel()
                peerConnectionTasks.removeValue(forKey: ObjectIdentifier(peer))
            }
            return shouldRemove
        }
        if peerConnections.count != before {
            TorrentLog.debug("[TorrentEngine] Pruned \(before - peerConnections.count) dead peers")
        }
    }

    private func expireStalledRequests() async {
        for peer in peerConnections {
            await peer.expireStalledRequests()
        }
    }

    private func handlePieceReceived(pieceIndex: UInt32, offset: UInt32, block: Data) async {
        _ = await PieceIngestion.apply(
            pieceStore: pieceStore,
            pieceManager: pieceManager,
            pieceIndex: pieceIndex,
            offset: offset,
            block: block
        )

        bytesDownloaded += Int64(block.count)
    }

    private func updateStats() async {
        recordBytesSample()
        await publishProgress()
    }

    private func publishProgress() async {
        let progress = await pieceManager.progress()
        downloadSpeed = recentDownloadSpeed()
        activePeerCount = transferringPeerCount()
        progressHandler(progress, downloadSpeed, livePeerCount())
    }

    private func recordBytesSample() {
        let now = Date.now
        recentBytesSamples.append((now, bytesDownloaded))
        let cutoff = now.addingTimeInterval(-3)
        recentBytesSamples.removeAll { $0.date < cutoff }
    }

    private func recentDownloadSpeed() -> Double {
        guard let oldest = recentBytesSamples.first,
              let newest = recentBytesSamples.last,
              newest.date > oldest.date else { return 0 }
        let deltaBytes = Double(newest.bytes - oldest.bytes)
        let deltaTime = newest.date.timeIntervalSince(oldest.date)
        return deltaTime > 0 ? deltaBytes / deltaTime : 0
    }

    private func peerKey(_ peer: PeerInfo) -> String {
        "\(peer.ip):\(peer.port)"
    }

    fileprivate func peerDiagnosticRows() -> [StreamDiagnosticsSnapshot.Row] {
        var stateCounts: [String: Int] = [:]
        for peer in peerConnections {
            let key: String = switch peer.state {
            case .connecting: "connecting"
            case .handshaking: "handshaking"
            case .connected: "connected"
            case .choked: "choked"
            case .unchoked: "unchoked"
            case .downloading: "downloading"
            case .disconnected: "disconnected"
            case .error: "error"
            }
            stateCounts[key, default: 0] += 1
        }

        var rows: [StreamDiagnosticsSnapshot.Row] = [
            .init(label: "Bytes downloaded", value: StreamDiagnosticsFormatting.bytes(bytesDownloaded)),
            .init(label: "Transferring peers", value: "\(activePeerCount)"),
            .init(label: "Live peers", value: "\(livePeerCount())"),
            .init(label: "Peer sockets", value: "\(peerConnections.count) / \(maxPeerConnections)"),
            .init(label: "DHT", value: dht != nil ? "Running" : "Off"),
            .init(label: "Trackers (metadata)", value: "\(metadata.trackers.count)"),
        ]

        for key in ["downloading", "unchoked", "connected", "handshaking", "choked", "connecting", "disconnected", "error"] {
            if let count = stateCounts[key], count > 0 {
                rows.append(.init(label: "Peers · \(key)", value: "\(count)"))
            }
        }

        return rows
    }

    deinit {
        let aTimer = announceTimer
        let sTimer = statsTimer
        let mTimer = maintenanceTimer
        let bTask = bootstrapTask
        let dhtInstance = dht
        let conns = peerConnections
        let tasks = peerConnectionTasks
        Task { @MainActor in
            aTimer?.cancel()
            sTimer?.cancel()
            mTimer?.cancel()
            bTask?.cancel()
            dhtInstance?.stop()
            for (_, task) in tasks {
                task.cancel()
            }
            for peer in conns {
                peer.disconnect()
            }
        }
    }
}
