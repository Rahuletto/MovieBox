# KT Appendix: Full Source Dumps (Playback Pipeline)

Generated from workspace sources. No truncation.

---
## `App/CoreStreaming/Sources/CoreStreaming/StreamingOrchestrator.swift`

```swift
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
        return url
    }

    public func stop() async {
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
        guard let pieceStore, let target = streamTarget, let metadata else { return false }
        guard target.needsTailProbeForPlayback else { return true }

        let verifiedHead = await pieceStore.verifiedMediaBytesFromStart()
        guard verifiedHead >= StreamPlaybackThreshold.minimumHeadBytes else { return false }

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
        guard await pieceStore.hasPiece(lastPiece) else { return false }

        // MP4/MOV with trailing moov: require a complete moov in the verified tail window.
        if target.needsMP4MoovTailProbe {
            if let tailData = await readVerifiedTailWindow(
                pieceStore: pieceStore,
                target: target,
                metadata: metadata
            ) {
                switch StreamTailPlanner.moovTailProbe(in: tailData, endsAtFileEOF: true) {
                case .complete:
                    TorrentLog.info("[Streaming] MP4 moov index verified in tail (\(tailData.count) bytes)")
                    return true
                case .incomplete:
                    TorrentLog.debug("[Streaming] MP4 moov in tail is still incomplete")
                    return false
                case .notFound:
                    break
                }
            } else {
                return false
            }
        }

        // MKV/WebM and moov-not-found fallbacks: need several verified tail pieces, not just the last byte.
        let tailIndices = StreamTailPlanner.tailPieceIndices(
            target: target,
            pieceLength: metadata.pieceLength,
            pieceCount: metadata.pieceCount
        )
        guard !tailIndices.isEmpty else { return true }

        var verifiedTail = 0
        for index in tailIndices where await pieceStore.hasPiece(index) {
            verifiedTail += 1
        }
        let required = max(2, min(tailIndices.count, (tailIndices.count + 2) / 3))
        return verifiedTail >= required
    }

    private func readVerifiedTailWindow(
        pieceStore: PieceStore,
        target: TorrentStreamTarget,
        metadata: TorrentMetadata
    ) async -> Data? {
        let tailSpan = StreamTailPlanner.tailByteSpan(
            byteLength: target.byteLength,
            pieceLength: metadata.pieceLength
        )
        let fileEnd = target.byteOffset + target.byteLength
        let tailStart = max(target.byteOffset, fileEnd - tailSpan)

        let lastPiece = min(target.lastPieceIndex, metadata.pieceCount - 1)
        guard await pieceStore.hasPiece(lastPiece) else { return nil }

        // Find the contiguous verified pieces starting from lastPiece going backwards
        var firstContiguousPiece = lastPiece
        while firstContiguousPiece > target.firstPieceIndex {
            let prevPiece = firstContiguousPiece - 1
            let prevPieceStart = Int64(prevPiece) * metadata.pieceLength
            if prevPieceStart < tailStart {
                break
            }
            if await pieceStore.hasPiece(prevPiece) {
                firstContiguousPiece = prevPiece
            } else {
                break
            }
        }

        let startOffset = max(target.byteOffset, Int64(firstContiguousPiece) * metadata.pieceLength)
        let length = Int(fileEnd - startOffset)
        guard length >= 16 else { return nil }

        return try? await pieceStore.read(offset: startOffset, length: length)
    }

    public func streamTailPieceCount() async -> Int {
        guard let target = streamTarget, let metadata else { return 0 }
        let span = StreamTailPlanner.tailByteSpan(
            byteLength: target.byteLength,
            pieceLength: metadata.pieceLength
        )
        return StreamTailPlanner.tailPieceIndices(
            target: target,
            pieceLength: metadata.pieceLength,
            pieceCount: metadata.pieceCount,
            tailByteSpan: span
        ).count
    }

    public func streamTailPiecesVerified() async -> Int {
        guard let pieceStore, let target = streamTarget, let metadata else { return 0 }
        let span = StreamTailPlanner.tailByteSpan(
            byteLength: target.byteLength,
            pieceLength: metadata.pieceLength
        )
        let indices = StreamTailPlanner.tailPieceIndices(
            target: target,
            pieceLength: metadata.pieceLength,
            pieceCount: metadata.pieceCount,
            tailByteSpan: span
        )
        var count = 0
        for index in indices where await pieceStore.hasPiece(index) {
            count += 1
        }
        return count
     }

     public func streamTailPiecesProgress() async -> Double {
         guard let pieceManager, let target = streamTarget, let metadata else { return 0 }
         let span = StreamTailPlanner.tailByteSpan(
             byteLength: target.byteLength,
             pieceLength: metadata.pieceLength
         )
         let indices = StreamTailPlanner.tailPieceIndices(
             target: target,
             pieceLength: metadata.pieceLength,
             pieceCount: metadata.pieceCount,
             tailByteSpan: span
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
        if target.contentType.contains("matroska") { return "MKV index (cues)" }
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
```

---
## `App/CoreStreaming/Sources/CoreStreaming/PieceStore.swift`

```swift
import Foundation

// MARK: - Piece Store

public actor PieceStore {
    public nonisolated let infoHash: String
    public nonisolated let pieceCount: Int
    public nonisolated let pieceSize: Int64
    public nonisolated let totalSize: Int64
    public nonisolated let storageURL: URL
    public let streamFirstPiece: Int
    /// Byte offset in the torrent where the streamed media file begins.
    public let streamMediaByteOffset: Int64

    private var bitmap: [Bool]
    private var writeHandle: FileHandle?
    private var readHandle: FileHandle?
    /// Contiguous bytes written from the start of the streamed media file (may be unverified).
    private var streamHeadContiguousEnd: Int64 = 0

    private struct CachedBlock {
        let torrentOffset: Int64
        let data: Data
    }
    private var writeCache: [CachedBlock] = []
    private let maxCacheSize = 2 * 1024 * 1024 // 2 MB
    private var currentCacheBytes = 0

    public init(
        infoHash: String,
        pieceCount: Int,
        pieceSize: Int64,
        totalSize: Int64? = nil,
        streamFirstPiece: Int = 0,
        streamMediaByteOffset: Int64 = 0,
        storageDirectory: URL = FileManager.default.temporaryDirectory,
        existingBitmap: Data? = nil,
        recreateFile: Bool = true
    ) async throws {
        self.infoHash = infoHash
        self.pieceCount = pieceCount
        self.pieceSize = pieceSize
        self.streamFirstPiece = streamFirstPiece
        self.streamMediaByteOffset = streamMediaByteOffset
        let resolvedTotalSize = totalSize ?? Int64(pieceCount) * pieceSize
        self.totalSize = resolvedTotalSize
        self.storageURL = storageDirectory.appendingPathComponent("moviebox_\(infoHash).stream")

        if let existingBitmap, !existingBitmap.isEmpty {
            self.bitmap = Self.decodeBitmap(existingBitmap, pieceCount: pieceCount)
        } else {
            self.bitmap = Array(repeating: false, count: pieceCount)
        }

        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        let fileExists = FileManager.default.fileExists(atPath: storageURL.path)
        if recreateFile || !fileExists {
            if fileExists {
                try FileManager.default.removeItem(at: storageURL)
            }
            FileManager.default.createFile(atPath: storageURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: storageURL)
            try handle.truncate(atOffset: UInt64(resolvedTotalSize))
            try handle.close()
        }

        self.writeHandle = try FileHandle(forWritingTo: storageURL)
        self.readHandle = try FileHandle(forReadingFrom: storageURL)
    }

    public func encodedBitmap() -> Data {
        Self.encodeBitmap(bitmap)
    }

    public static func encodeBitmap(_ bitmap: [Bool]) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity((bitmap.count + 7) / 8)
        var current: UInt8 = 0
        var bitIndex = 0
        for piece in bitmap {
            if piece {
                current |= 1 << (7 - bitIndex)
            }
            bitIndex += 1
            if bitIndex == 8 {
                bytes.append(current)
                current = 0
                bitIndex = 0
            }
        }
        if bitIndex > 0 {
            bytes.append(current)
        }
        return Data(bytes)
    }

    public static func decodeBitmap(_ data: Data, pieceCount: Int) -> [Bool] {
        var result = [Bool]()
        result.reserveCapacity(pieceCount)
        for byte in data {
            for bit in 0..<8 where result.count < pieceCount {
                result.append((byte >> (7 - bit)) & 1 != 0)
            }
        }
        while result.count < pieceCount {
            result.append(false)
        }
        return result
    }

    private func queueWrite(torrentOffset: Int64, data: Data) throws {
        writeCache.append(CachedBlock(torrentOffset: torrentOffset, data: data))
        currentCacheBytes += data.count

        if currentCacheBytes >= maxCacheSize {
            try flushCache()
        }
    }

    private func flushCache() throws {
        guard !writeCache.isEmpty else { return }
        guard let writeHandle else {
            throw PieceStoreError.ioError("Write handle unavailable")
        }

        for block in writeCache {
            try writeHandle.seek(toOffset: UInt64(block.torrentOffset))
            writeHandle.write(block.data)
        }

        writeCache.removeAll(keepingCapacity: true)
        currentCacheBytes = 0
    }

    /// Writes a block to disk immediately for progressive playback (before hash verification).
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
            // Advance the contiguous head if this block connects to the current end.
            // Also seed the head from offset 0 if this is the first block of the first
            // piece — even when streamMediaByteOffset places mediaStart > 0, the actual
            // content is still contiguous from byte 0 of the media.
            let connectsToHead = mediaStart <= streamHeadContiguousEnd
            let isFirstBlock = pieceIndex == streamFirstPiece && blockOffset == 0
            if connectsToHead || (isFirstBlock && streamHeadContiguousEnd == 0) {
                streamHeadContiguousEnd = max(streamHeadContiguousEnd, mediaEnd)
            }
        }
    }

    public func markPieceVerified(pieceIndex: Int) {
        guard pieceIndex >= 0, pieceIndex < pieceCount else { return }
        bitmap[pieceIndex] = true
    }

    public func write(pieceIndex: Int, data: Data) async throws {
        guard pieceIndex >= 0 && pieceIndex < pieceCount else {
            throw PieceStoreError.invalidPieceIndex(pieceIndex)
        }
        guard data.count <= pieceSize else {
            throw PieceStoreError.pieceTooLarge(data.count, pieceSize)
        }

        let offset = Int64(pieceIndex) * pieceSize
        try queueWrite(torrentOffset: offset, data: data)
        bitmap[pieceIndex] = true

        let blockStart = offset
        let blockEnd = offset + Int64(data.count)
        let mediaStart = max(0, blockStart - streamMediaByteOffset)
        let mediaEnd = max(0, blockEnd - streamMediaByteOffset)
        if mediaEnd > mediaStart {
            let connectsToHead = mediaStart <= streamHeadContiguousEnd
            let isFirstPiece = pieceIndex == streamFirstPiece
            if connectsToHead || (isFirstPiece && streamHeadContiguousEnd == 0) {
                streamHeadContiguousEnd = max(streamHeadContiguousEnd, mediaEnd)
            }
        }
    }

    public func read(offset: Int64, length: Int) async throws -> Data {
        let clampedLength = min(length, Int(totalSize - offset))
        guard offset >= 0, clampedLength > 0, offset < totalSize else {
            throw PieceStoreError.outOfRange(offset, totalSize)
        }

        try flushCache()

        try await waitForReadable(offset: offset, length: clampedLength)

        try flushCache()

        guard let readHandle else {
            throw PieceStoreError.ioError("Read handle unavailable")
        }
        try readHandle.seek(toOffset: UInt64(offset))
        return readHandle.readData(ofLength: clampedLength)
    }

    public func hasPiece(_ index: Int) -> Bool {
        guard index >= 0 && index < bitmap.count else { return false }
        return bitmap[index]
    }

    public func progress() -> Double {
        guard pieceCount > 0 else { return 0 }
        let completed = bitmap.filter { $0 }.count
        return Double(completed) / Double(pieceCount)
    }

    public func contiguousPiecesFromStart() -> Int {
        var count = 0
        for index in streamFirstPiece..<bitmap.count {
            guard bitmap[index] else { break }
            count += 1
        }
        return count
    }

    public func contiguousBytesFromStreamStart() -> Int64 {
        var bytes: Int64 = 0
        for index in streamFirstPiece..<bitmap.count {
            guard bitmap[index] else { break }
            if index == pieceCount - 1 {
                bytes += totalSize - Int64(index) * pieceSize
            } else {
                bytes += pieceSize
            }
        }
        return bytes
    }

    /// Verified media bytes available from the start of the streamed file.
    public func verifiedMediaBytesFromStart() -> Int64 {
        let torrentBytes = contiguousBytesFromStreamStart()
        let pieceBase = Int64(streamFirstPiece) * pieceSize
        let prefix = max(0, streamMediaByteOffset - pieceBase)
        return max(0, torrentBytes - prefix)
    }

    /// Contiguous media bytes at the file head (includes in-flight blocks written before verify).
    public func streamHeadContiguousBytes() -> Int64 {
        streamHeadContiguousEnd
    }

    public func readableLength(offset: Int64, length: Int) -> Int {
        readableSpan(offset: offset, length: length, preferSuffix: false)?.length ?? 0
    }

    public func readableSpan(
        offset: Int64,
        length: Int,
        preferSuffix: Bool = false
    ) -> (offset: Int64, length: Int)? {
        let rangeEnd = min(offset + Int64(length), totalSize)
        guard offset >= 0, offset < totalSize, rangeEnd > offset else { return nil }

        if !preferSuffix {
            let prefix = readablePrefixLength(offset: offset, rangeEnd: rangeEnd)
            return prefix > 0 ? (offset, prefix) : nil
        }

        let firstPiece = Int(offset / pieceSize)
        let lastPiece = Int((rangeEnd - 1) / pieceSize)
        for pieceIndex in stride(from: lastPiece, through: firstPiece, by: -1) {
            let pieceStart = Int64(pieceIndex) * pieceSize
            let spanStart = max(offset, pieceStart)
            let spanEnd = min(rangeEnd, pieceStart + pieceSize(for: pieceIndex))
            let spanLen = Int(spanEnd - spanStart)
            guard spanLen > 0 else { continue }
            let available = readablePrefixLength(offset: spanStart, rangeEnd: spanEnd)
            if available > 0 {
                return (spanStart, available)
            }
        }
        return nil
    }

    private func readablePrefixLength(offset: Int64, rangeEnd: Int64) -> Int {
        var position = offset
        while position < rangeEnd {
            let pieceIndex = Int(position / pieceSize)
            if hasPiece(pieceIndex) {
                let pieceStart = Int64(pieceIndex) * pieceSize
                let pieceEnd = min(rangeEnd, pieceStart + pieceSize(for: pieceIndex))
                position = pieceEnd
                continue
            }

            // Check if within the contiguous unverified stream head.
            let mediaOffset = position - streamMediaByteOffset
            if mediaOffset >= 0 && mediaOffset < streamHeadContiguousEnd {
                let mediaEnd = min(rangeEnd - streamMediaByteOffset, streamHeadContiguousEnd)
                position = mediaEnd + streamMediaByteOffset
                continue
            }

            break
        }
        return Int(position - offset)
    }

    public func cleanup() async {
        try? writeHandle?.close()
        try? readHandle?.close()
        writeHandle = nil
        readHandle = nil
        try? FileManager.default.removeItem(at: storageURL)
    }

    public func closeHandles() async {
        try? writeHandle?.close()
        try? readHandle?.close()
        writeHandle = nil
        readHandle = nil
    }

    deinit {
        try? writeHandle?.close()
        try? readHandle?.close()
    }

    private func waitForReadable(offset: Int64, length: Int) async throws {
        let end = offset + Int64(length)
        var waitCount = 0

        while true {
            try Task.checkCancellation()
            if isRangeReadable(offset: offset, end: end) {
                return
            }

            waitCount += 1
            if waitCount % 50 == 0 {
                TorrentLog.debug(
                    "[PieceStore] Waiting for readable bytes \(offset)-\(end) (head contiguous: \(streamHeadContiguousEnd))"
                )
            }
            if waitCount >= 3000 {
                TorrentLog.error("[PieceStore] Read timeout waiting for range \(offset)-\(end)")
                throw PieceStoreError.readTimeout(offset, length)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func isRangeReadable(offset: Int64, end: Int64) -> Bool {
        var position = offset
        while position < end {
            let pieceIndex = Int(position / pieceSize)
            if hasPiece(pieceIndex) {
                let pieceStart = Int64(pieceIndex) * pieceSize
                let pieceEnd = min(end, pieceStart + pieceSize(for: pieceIndex))
                position = pieceEnd
                continue
            }
            
            // Check if within the contiguous unverified stream head.
            let mediaOffset = position - streamMediaByteOffset
            if mediaOffset >= 0 && mediaOffset < streamHeadContiguousEnd {
                let mediaEnd = min(end - streamMediaByteOffset, streamHeadContiguousEnd)
                position = mediaEnd + streamMediaByteOffset
                continue
            }
            
            return false
        }
        return true
    }

    /// Drops unverified bytes for a piece after hash failure so AVPlayer cannot read stale data.
    public func invalidatePiece(_ pieceIndex: Int) async throws {
        guard pieceIndex >= 0, pieceIndex < pieceCount else {
            throw PieceStoreError.invalidPieceIndex(pieceIndex)
        }

        let pieceStart = Int64(pieceIndex) * pieceSize
        let pieceEnd = pieceStart + pieceSize(for: pieceIndex)
        writeCache.removeAll { block in
            block.torrentOffset >= pieceStart && block.torrentOffset < pieceEnd
        }
        currentCacheBytes = writeCache.reduce(0) { $0 + $1.data.count }

        guard let writeHandle else {
            throw PieceStoreError.ioError("Write handle unavailable")
        }

        let offset = Int64(pieceIndex) * pieceSize
        let length = Int(pieceSize(for: pieceIndex))
        try writeHandle.seek(toOffset: UInt64(offset))
        writeHandle.write(Data(repeating: 0, count: length))
        bitmap[pieceIndex] = false
        recomputeStreamHeadContiguousEnd()
    }

    private func recomputeStreamHeadContiguousEnd() {
        var end: Int64 = 0
        for index in streamFirstPiece..<pieceCount {
            guard hasPiece(index) else { break }
            let pieceStart = Int64(index) * pieceSize
            let pieceEnd = pieceStart + pieceSize(for: index)
            
            let mediaStart = max(0, pieceStart - streamMediaByteOffset)
            let mediaEnd = max(0, pieceEnd - streamMediaByteOffset)
            
            if mediaEnd > mediaStart {
                end = max(end, mediaEnd)
            }
        }
        streamHeadContiguousEnd = end
    }

    private func pieceSize(for pieceIndex: Int) -> Int64 {
        if pieceIndex == pieceCount - 1 {
            return totalSize - Int64(pieceIndex) * pieceSize
        }
        return pieceSize
    }
}

public enum PieceStoreError: Error, LocalizedError {
    case invalidPieceIndex(Int)
    case pieceTooLarge(Int, Int64)
    case outOfRange(Int64, Int64)
    case ioError(String)
    case readTimeout(Int64, Int)

    public var errorDescription: String? {
        switch self {
        case .invalidPieceIndex(let index):
            "Invalid piece index: \(index)"
        case .pieceTooLarge(let size, let max):
            "Piece size \(size) exceeds maximum \(max)"
        case .outOfRange(let offset, let total):
            "Offset \(offset) out of range (total: \(total))"
        case .ioError(let message):
            "I/O error: \(message)"
        case .readTimeout(let offset, let length):
            "Read timeout waiting for range: \(offset) (length: \(length))"
        }
    }
}
```

---
## `App/CoreStreaming/Sources/CoreStreaming/PieceManager.swift`

```swift
import Foundation
import CryptoKit

// MARK: - Piece Manager (Streaming Priority)

public enum PieceReceiveOutcome: Sendable {
    case incomplete
    case verified
    case rejected
}

public actor PieceManager {
    public let pieceCount: Int
    public let pieceLength: Int64
    public let totalSize: Int64
    public let blockSize: UInt32 = 16384
    public let streamFirstPiece: Int
    public let streamLastPiece: Int
    public let streamTailPieces: [Int]
    public let streamMediaByteOffset: Int64
    public let streamMediaByteLength: Int64

    private var pieceHashes: [Data] = []
    private var downloadedPieces: Set<UInt32> = []
    private var pendingRequests: Set<BlockRequest> = []
    private var pieceBuffers: [UInt32: Data] = [:]
    private var receivedBlockOffsets: [UInt32: Set<UInt32>] = [:]
    /// Pieces AVPlayer recently requested via HTTP ranges (newest first).
    private var playerHotPieces: [UInt32] = []

    private static let maxHotPieces = 32
    private static let readAheadPieceCount = 3

    public init(
        pieceCount: Int,
        pieceLength: Int64,
        totalSize: Int64,
        piecesHash: Data,
        streamFirstPiece: Int = 0,
        streamLastPiece: Int? = nil,
        streamTailPieces: [Int]? = nil,
        streamMediaByteOffset: Int64 = 0,
        streamMediaByteLength: Int64? = nil
    ) {
        self.pieceCount = pieceCount
        self.pieceLength = pieceLength
        self.totalSize = totalSize
        self.streamFirstPiece = streamFirstPiece
        self.streamMediaByteOffset = streamMediaByteOffset
        self.streamMediaByteLength = streamMediaByteLength ?? max(0, totalSize - streamMediaByteOffset)
        if let streamTailPieces, !streamTailPieces.isEmpty {
            self.streamTailPieces = streamTailPieces
            self.streamLastPiece = streamTailPieces.max() ?? max(0, pieceCount - 1)
        } else {
            let last = streamLastPiece ?? max(0, pieceCount - 1)
            self.streamLastPiece = last
            self.streamTailPieces = [last]
        }

        let cleanHash = Data(piecesHash)
        var index = 0
        while index + 20 <= cleanHash.count {
            pieceHashes.append(cleanHash[index..<index + 20])
            index += 20
        }
    }

    public func setInitialDownloadedPieces(_ pieces: Set<UInt32>) {
        downloadedPieces = pieces
    }

    public func getNextRequest(peerBitfield: Data = Data()) -> BlockRequest? {
        guard let pieceIndex = earliestIncompletePiece(peerBitfield: peerBitfield) else { return nil }

        let pieceSize = pieceSize(for: pieceIndex)
        let blockCount = Int((pieceSize + Int64(blockSize) - 1) / Int64(blockSize))

        for blockIndex in 0..<blockCount {
            let offset = UInt32(blockIndex) * blockSize
            if receivedBlockOffsets[pieceIndex]?.contains(offset) == true {
                continue
            }

            let length = min(blockSize, UInt32(pieceSize) - offset)
            let request = BlockRequest(pieceIndex: pieceIndex, offset: offset, length: length)

            guard !pendingRequests.contains(request) else { continue }

            pendingRequests.insert(request)
            return request
        }

        return nil
    }

    public func recycleRequests(_ requests: [BlockRequest]) {
        for request in requests {
            pendingRequests.remove(request)
        }
    }

    public func markBlockReceived(pieceIndex: UInt32, offset: UInt32, block: Data) -> PieceReceiveOutcome {
        pendingRequests.remove(BlockRequest(pieceIndex: pieceIndex, offset: offset, length: 0))

        let expectedSize = Int(pieceSize(for: pieceIndex))
        if pieceBuffers[pieceIndex] == nil {
            pieceBuffers[pieceIndex] = Data(count: expectedSize)
        }

        guard var buffer = pieceBuffers[pieceIndex] else { return .incomplete }

        let start = Int(offset)
        let end = start + block.count
        guard start >= 0, end <= buffer.count else { return .incomplete }

        buffer.replaceSubrange(start..<end, with: block)
        pieceBuffers[pieceIndex] = buffer

        var offsets = receivedBlockOffsets[pieceIndex] ?? []
        offsets.insert(offset)
        receivedBlockOffsets[pieceIndex] = offsets

        guard isPieceFullyReceived(pieceIndex: pieceIndex, expectedSize: expectedSize) else {
            return .incomplete
        }

        guard verifyPiece(pieceIndex: pieceIndex, data: buffer) else {
            return .rejected
        }

        return .verified
    }

    public func cancelPendingRequests() -> [BlockRequest] {
        let requests = Array(pendingRequests)
        pendingRequests.removeAll()
        return requests
    }

    public func isPieceDownloaded(_ pieceIndex: UInt32) -> Bool {
        downloadedPieces.contains(pieceIndex)
    }

    public func pieceProgress(pieceIndex: UInt32) -> Double {
        if downloadedPieces.contains(pieceIndex) {
            return 1.0
        }
        guard let offsets = receivedBlockOffsets[pieceIndex] else { return 0.0 }
        let size = Double(pieceSize(for: pieceIndex))
        guard size > 0 else { return 0.0 }
        
        let received = offsets.reduce(0.0) { sum, offset in
            let blockLen = min(Double(blockSize), size - Double(offset))
            return sum + max(0.0, blockLen)
        }
        return min(1.0, received / size)
    }

    public func progress() -> Double {
        guard pieceCount > 0 else { return 0 }
        return Double(downloadedPieces.count) / Double(pieceCount)
    }

    public func downloadedCount() -> Int {
        downloadedPieces.count
    }

    public func pendingRequestCount() -> Int {
        pendingRequests.count
    }

    public func takePieceData(_ pieceIndex: UInt32) -> Data? {
        defer { pieceBuffers.removeValue(forKey: pieceIndex) }
        return pieceBuffers[pieceIndex]
    }

    /// Called when AVPlayer requests a byte range — boosts torrent piece priority for that span.
    public func notePlayerRead(mediaOffset: Int64, length: Int) {
        let indices = pieceIndicesCovering(mediaOffset: mediaOffset, length: length)
        guard !indices.isEmpty else { return }

        var expanded = indices
        if let last = indices.last {
            for ahead in 1...Self.readAheadPieceCount {
                let next = last + UInt32(ahead)
                guard Int(next) < pieceCount else { break }
                expanded.append(next)
            }
        }

        for index in expanded.reversed() {
            playerHotPieces.removeAll { $0 == index }
            playerHotPieces.insert(index, at: 0)
        }
        if playerHotPieces.count > Self.maxHotPieces {
            playerHotPieces.removeLast(playerHotPieces.count - Self.maxHotPieces)
        }
    }

    public func playerHotPieceCount() -> Int {
        playerHotPieces.count
    }

    /// Until head + tail index pieces are verified, never fall back to middle-of-file pieces
    /// (peers without end-of-file in bitfield would otherwise pull piece 1, 2, … forever).
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

        for index in playerHotPieces {
            append(index)
        }
        append(UInt32(streamFirstPiece))
        for piece in streamTailPieces.reversed() {
            append(UInt32(piece))
        }
        return priority
    }

    private func buildFullPriorityOrder() -> [UInt32] {
        var priority = buildBootstrapPriorityOrder()
        func append(_ index: UInt32) {
            guard !priority.contains(index) else { return }
            priority.append(index)
        }

        for i in streamFirstPiece..<pieceCount {
            append(UInt32(i))
        }
        return priority
    }

    private func pieceIndicesCovering(mediaOffset: Int64, length: Int) -> [UInt32] {
        guard length > 0, mediaOffset >= 0 else { return [] }
        let span = min(Int64(length), streamMediaByteLength - mediaOffset)
        guard span > 0 else { return [] }

        let torrentStart = streamMediaByteOffset + mediaOffset
        let torrentEnd = torrentStart + span - 1
        let first = max(0, Int(torrentStart / pieceLength))
        let last = min(pieceCount - 1, Int(torrentEnd / pieceLength))
        guard first <= last else { return [] }
        return (first...last).map { UInt32($0) }
    }

    private func isPieceFullyReceived(pieceIndex: UInt32, expectedSize: Int) -> Bool {
        let blockCount = Int((Int64(expectedSize) + Int64(blockSize) - 1) / Int64(blockSize))
        guard let offsets = receivedBlockOffsets[pieceIndex], offsets.count >= blockCount else {
            return false
        }
        for blockIndex in 0..<blockCount {
            let offset = UInt32(blockIndex) * blockSize
            if !offsets.contains(offset) { return false }
        }
        return true
    }

    private func resetPiece(_ pieceIndex: UInt32) {
        pieceBuffers[pieceIndex] = nil
        receivedBlockOffsets[pieceIndex] = nil
        pendingRequests = pendingRequests.filter { $0.pieceIndex != pieceIndex }
    }

    private func pieceSize(for pieceIndex: UInt32) -> Int64 {
        let index = Int(pieceIndex)
        if index == pieceCount - 1 {
            return totalSize - (Int64(index) * pieceLength)
        }
        return pieceLength
    }

    private func peerHasPiece(_ pieceIndex: UInt32, in bitfield: Data) -> Bool {
        let byteIndex = Int(pieceIndex / 8)
        let bitIndex = Int(pieceIndex % 8)
        guard byteIndex < bitfield.count else { return false }
        return (bitfield[byteIndex] & (1 << (7 - bitIndex))) != 0
    }

    private func verifyPiece(pieceIndex: UInt32, data: Data) -> Bool {
        guard Int(pieceIndex) < pieceHashes.count else { return false }

        let computedHash = Data(Insecure.SHA1.hash(data: data))
        guard computedHash == pieceHashes[Int(pieceIndex)] else {
            TorrentLog.debug("[PieceManager] Hash mismatch on piece \(pieceIndex), retrying")
            resetPiece(pieceIndex)
            return false
        }

        downloadedPieces.insert(pieceIndex)
        pieceBuffers.removeValue(forKey: pieceIndex)
        receivedBlockOffsets.removeValue(forKey: pieceIndex)
        trimPieceBuffers(keeping: pieceIndex)
        return true
    }

    private func trimPieceBuffers(keeping current: UInt32) {
        let maxBuffers = 64
        guard pieceBuffers.count > maxBuffers else { return }

        let tailSet = Set(streamTailPieces.map { UInt32($0) })
        let hotSet = Set(playerHotPieces)

        let candidates = pieceBuffers.keys.filter { key in
            key != current && !tailSet.contains(key) && !hotSet.contains(key)
        }

        for key in candidates {
            resetPiece(key)
            if pieceBuffers.count <= maxBuffers { break }
        }
    }
}

public struct BlockRequest: Hashable, Sendable {
    public let pieceIndex: UInt32
    public let offset: UInt32
    public let length: UInt32

    public init(pieceIndex: UInt32, offset: UInt32, length: UInt32) {
        self.pieceIndex = pieceIndex
        self.offset = offset
        self.length = length
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(pieceIndex)
        hasher.combine(offset)
    }

    public static func == (lhs: BlockRequest, rhs: BlockRequest) -> Bool {
        lhs.pieceIndex == rhs.pieceIndex && lhs.offset == rhs.offset
    }
}
```

---
## `App/CoreStreaming/Sources/CoreStreaming/StreamSession.swift`

```swift
import CoreStorage
import CoreTorrent
import Foundation

@MainActor
public final class StreamSession<O: StreamingOrchestration & Sendable>: ObservableObject {
    public enum State: Equatable {
        case idle
        case preparing
        case buffering(progress: Double)
        case ready(streamURL: URL)
        case failed(error: String)
        case cancelled

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): true
            case (.preparing, .preparing): true
            case (.buffering(let p1), .buffering(let p2)): p1 == p2
            case (.ready(let u1), .ready(let u2)): u1 == u2
            case (.failed(let e1), .failed(let e2)): e1 == e2
            case (.cancelled, .cancelled): true
            default: false
            }
        }
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var downloadSpeed: Double = 0
    @Published public private(set) var peerCount: Int = 0
    @Published public private(set) var transferringPeerCount: Int = 0
    @Published public private(set) var bufferedPieces: Int = 0
    @Published public private(set) var bufferedBytes: Int64 = 0
    /// Seeders reported by the indexer (Jackett/Prowlarr) — not the same as live peer connections.
    public private(set) var swarmSeeders: Int = 0
    public private(set) var swarmLeechers: Int = 0
    public private(set) var activeTorrent: TorrentResult?

    private let orchestrator: O
    private var monitorTask: Task<Void, Never>?
    private var bufferingWatchdogTask: Task<Void, Never>?
    private var streamURL: URL?

    public init(orchestrator: O) {
        self.orchestrator = orchestrator
    }

    deinit {
        let watchdog = bufferingWatchdogTask
        let monitor = monitorTask
        let orch = orchestrator
        Task { @MainActor in
            watchdog?.cancel()
            monitor?.cancel()
            await orch.stop()
        }
    }

    public func start(torrent: TorrentResult) async {
        bufferingWatchdogTask?.cancel()
        bufferingWatchdogTask = nil
        monitorTask?.cancel()
        monitorTask = nil

        state = .preparing
        streamURL = nil
        bufferedPieces = 0
        bufferedBytes = 0
        activeTorrent = torrent
        swarmSeeders = torrent.seeders
        swarmLeechers = torrent.leechers

        let hash = torrent.infoHash ?? "unknown"
        TorrentLog.info(
            "[StreamSession] start — \"\(torrent.title)\" quality=\(torrent.quality.rawValue) indexerSeeders=\(torrent.seeders) indexerLeechers=\(torrent.leechers) size=\(torrent.sizeBytes) hash=\(hash.prefix(8))…"
        )

        do {
            let orchestrator = orchestrator
            streamURL = try await TaskTimeout.withTimeout(seconds: 50) {
                try await orchestrator.startStream(torrent: torrent) { [weak self] progress, speed, peers in
                    Task { @MainActor in
                        guard let self else { return }
                        self.downloadSpeed = speed
                        self.peerCount = peers
                        self.transferringPeerCount = await orchestrator.transferringPeerCount()
                        await self.refreshBufferMetrics()
                        await self.updatePlaybackReadiness(progress: progress)
                    }
                }
            }

            await refreshBufferMetrics()
            await updatePlaybackReadiness(progress: await orchestrator.progress())
            TorrentLog.info(
                "[StreamSession] orchestrator ready — streamURL=\(MovieBoxFileLogger.redactURL(streamURL!)) headKB=\(bufferedBytes / 1024) state=\(stateLabel)"
            )
            startMonitoring()
            startBufferingWatchdog()
        } catch is TaskTimeoutError {
            await orchestrator.stop()
            let message = "Could not load torrent metadata in time. Try another release."
            TorrentLog.warn("[StreamSession] failed — metadata timeout (50s) for \"\(torrent.title)\"")
            state = .failed(error: message)
        } catch {
            await orchestrator.stop()
            TorrentLog.warn("[StreamSession] failed — \(error.localizedDescription) for \"\(torrent.title)\"")
            state = .failed(error: error.localizedDescription)
        }
    }

    private func refreshBufferMetrics() async {
        bufferedPieces = await orchestrator.contiguousPiecesFromStart()
        let verifiedBytes = await orchestrator.verifiedMediaBytesFromStart()
        let inFlightBytes = await orchestrator.streamHeadContiguousBytes()
        bufferedBytes = max(verifiedBytes, inFlightBytes)
    }

    private func tailBufferProgress() async -> (verified: Int, total: Int) {
        guard await orchestrator.streamTargetNeedsTailProbe() else { return (1, 1) }
        if let engine = orchestrator as? StreamingOrchestrator {
            let verified = await engine.streamTailPiecesVerified()
            let total = await engine.streamTailPieceCount()
            return (verified, max(1, total))
        }
        let ready = await orchestrator.isStreamTailPieceReady()
        return (ready ? 1 : 0, 1)
    }

    private func bufferingWatchdogSeconds() async -> UInt64 {
        guard await orchestrator.streamTargetNeedsTailProbe() else { return 120 }
        if let engine = orchestrator as? StreamingOrchestrator {
            let tailTotal = await engine.streamTailPieceCount()
            return UInt64(max(180, 90 + tailTotal * 18))
        }
        return 180
    }

    private func startBufferingWatchdog() {
        bufferingWatchdogTask?.cancel()
        bufferingWatchdogTask = Task { @MainActor [weak self] in
            guard let timeout = await self?.bufferingWatchdogSeconds() else { return }
            
            var lastProgressTime = Date.now
            var lastVerifiedBytes: Int64 = 0
            var lastInFlightBytes: Int64 = 0
            var lastTailVerified = 0
            
            let checkInterval: UInt64 = 5
            
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(checkInterval))
                } catch {
                    return
                }
                
                guard let self else { return }
                if case .ready = state { return }
                
                let currentVerifiedBytes = await orchestrator.verifiedMediaBytesFromStart()
                let currentInFlightBytes = await orchestrator.streamHeadContiguousBytes()
                let (currentTailVerified, _) = await tailBufferProgress()
                
                if currentVerifiedBytes > lastVerifiedBytes || currentInFlightBytes > lastInFlightBytes || currentTailVerified > lastTailVerified || downloadSpeed > 0 {
                    lastProgressTime = Date.now
                }
                
                lastVerifiedBytes = currentVerifiedBytes
                lastInFlightBytes = currentInFlightBytes
                lastTailVerified = currentTailVerified
                
                let elapsedStall = Date.now.timeIntervalSince(lastProgressTime)
                if elapsedStall >= Double(timeout) {
                    break
                }
            }
            
            guard let self else { return }
            guard !Task.isCancelled else { return }
            if case .ready = state { return }
            
            switch state {
            case .preparing, .buffering:
                let peersSnapshot = await orchestrator.peerCount()
                let transferringSnapshot = await orchestrator.transferringPeerCount()
                let verifiedKB = await orchestrator.contiguousBytesFromStreamStart() / 1024
                let inFlightKB = await orchestrator.streamHeadContiguousBytes() / 1024
                let needsTail = await orchestrator.streamTargetNeedsTailProbe()
                let hasTail = needsTail ? await orchestrator.isStreamTailPieceReady() : true
                let minKB = StreamPlaybackThreshold.minimumHeadBytes / 1024
                let (tailVerified, tailTotal) = await tailBufferProgress()
                await orchestrator.stop()
                let message: String
                if verifiedKB == 0, inFlightKB == 0 {
                    if transferringSnapshot == 0, peersSnapshot > 0 {
                        message =
                            "Peers connected but none are sending data (0 transferring / \(peersSnapshot) live). The swarm may be stale or blocking leechers — try another release."
                    } else if peersSnapshot == 0 {
                        message =
                            "No peers returned data — trackers may be unreachable or this swarm is dead. Try another version."
                    } else {
                        message =
                            "Buffering timed out with no data received (\(transferringSnapshot) transferring / \(peersSnapshot) live peer(s)). Try another release."
                    }
                } else if needsTail, !hasTail {
                    let indexLabel = await orchestrator.streamIndexProbeLabel()
                    message =
                        "Buffering stalled — waiting for \(indexLabel) (\(tailVerified)/\(tailTotal) tail pieces, \(verifiedKB) KB verified head). Try another release."
                } else if verifiedKB < minKB {
                    message =
                        "Buffering stalled at \(verifiedKB) KB verified head (need ~\(minKB) KB). \(inFlightKB) KB received but not hash-verified yet. \(transferringSnapshot) transferring / \(peersSnapshot) live peer(s)."
                } else if peersSnapshot == 0 {
                    message =
                        "No peers returned data — trackers may be unreachable or this swarm is dead. Try another version."
                } else {
                    message =
                        "Buffering timed out (\(transferringSnapshot) transferring / \(peersSnapshot) live peer(s)). Try another release."
                }
                TorrentLog.warn("[StreamSession] buffering watchdog — \(message)")
                state = .failed(error: message)
                monitorTask?.cancel()
                monitorTask = nil
            default:
                break
            }
        }
    }

    public func cancel() async {
        TorrentLog.info("[StreamSession] cancel — was \(stateLabel)")
        bufferingWatchdogTask?.cancel()
        bufferingWatchdogTask = nil
        state = .cancelled
        activeTorrent = nil
        monitorTask?.cancel()
        monitorTask = nil
        await orchestrator.stop()
    }

    public func failWithTimeout() async {
        TorrentLog.warn("[StreamSession] waitForPlayback timeout — state was \(stateLabel)")
        bufferingWatchdogTask?.cancel()
        bufferingWatchdogTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        await orchestrator.stop()
        state = .failed(error: "Streaming timed out. Try another release or check your connection.")
    }

    private func startMonitoring() {
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                var shouldContinue = false
                do {
                    guard let strongSelf = self else { break }
                    let progress = await strongSelf.orchestrator.progress()
                    let speed = await strongSelf.orchestrator.downloadSpeed()
                    let peers = await strongSelf.orchestrator.peerCount()
                    let transferring = await strongSelf.orchestrator.transferringPeerCount()

                    strongSelf.downloadSpeed = speed
                    strongSelf.peerCount = peers
                    strongSelf.transferringPeerCount = transferring
                    await strongSelf.refreshBufferMetrics()
                    await strongSelf.updatePlaybackReadiness(progress: progress)
                    shouldContinue = true
                }

                guard shouldContinue else { break }

                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    break
                }
            }
        }
    }

    private func updatePlaybackReadiness(progress: Double) async {
        guard let url = streamURL else {
            state = .preparing
            return
        }

        let verifiedHeadBytes = await orchestrator.verifiedMediaBytesFromStart()
        let inFlightHeadBytes = await orchestrator.streamHeadContiguousBytes()
        let hasEnoughHead = (bufferedPieces >= 1) || (verifiedHeadBytes >= StreamPlaybackThreshold.minimumHeadBytes)
        let needsTail = await orchestrator.streamTargetNeedsTailProbe()
        let hasTail = needsTail ? await orchestrator.isStreamTailPieceReady() : true

        if hasEnoughHead, hasTail {
            if case .ready = state {} else {
                let (tailVerified, tailTotal) = await tailBufferProgress()
                TorrentLog.info(
                    "[StreamSession] buffer ready — \(verifiedHeadBytes / 1024) KB verified head (\(inFlightHeadBytes / 1024) KB in-flight, need \(StreamPlaybackThreshold.minimumHeadBytes / 1024) KB), tail=\(tailVerified)/\(tailTotal) pieces, \(bufferedPieces) contiguous head piece(s), \(peerCount) live peers (\(transferringPeerCount) transferring)"
                )
                state = .ready(streamURL: url)
            }
        } else {
            // Drive progress from head accumulation (0→90%) + tail progress (0→10%).
            // AVPlayer fetches moov/index tail via range requests once pieces are downloaded.
            let tailFraction = await orchestrator.streamTailPiecesProgress()
            let headProgress = min(1.0, Double(verifiedHeadBytes) / Double(StreamPlaybackThreshold.minimumHeadBytes))
            let tailProgress = min(1.0, tailFraction)
            let overallProgress = (headProgress * 0.90) + (tailProgress * 0.10)
            let hint = max(progress, overallProgress, 0.02)
            if case .preparing = state {
                TorrentLog.info(
                    "[StreamSession] buffering — \(verifiedHeadBytes / 1024)/\(StreamPlaybackThreshold.minimumHeadBytes / 1024) KB verified head (\(inFlightHeadBytes / 1024) KB in-flight), \(peerCount) live peers (\(transferringPeerCount) transferring, indexer: \(swarmSeeders) seeders), \(Int(downloadSpeed / 1024)) KB/s"
                )
            }
            state = .buffering(progress: hint)
        }
    }

    /// Verified bytes from the stream file start (hash-checked). Safe to call from app modules.
    public func verifiedHeadBytes() async -> Int64 {
        await orchestrator.verifiedMediaBytesFromStart()
    }

    var activeStreamURL: URL? {
        if case .ready(let url) = state { return url }
        return streamURL
    }

    /// Human-readable state for logging (no PII).
    public var stateLabel: String {
        switch state {
        case .idle: "idle"
        case .preparing: "preparing"
        case .buffering(let p): "buffering(\(Int(p * 100))%)"
        case .ready: "ready"
        case .failed(let e): "failed(\(e.prefix(80)))"
        case .cancelled: "cancelled"
        }
    }

    public func rowBufferingMetrics() async -> StreamRowBufferingMetrics {
        let progress: Double
        let isPreparing: Bool
        let isReady: Bool
        let failedMessage: String?

        switch state {
        case .idle:
            progress = 0.04
            isPreparing = true
            isReady = false
            failedMessage = nil
        case .preparing:
            progress = 0.08
            isPreparing = true
            isReady = false
            failedMessage = nil
        case .buffering(let hint):
            progress = hint
            isPreparing = false
            isReady = false
            failedMessage = nil
        case .ready:
            progress = 1
            isPreparing = false
            isReady = true
            failedMessage = nil
        case .failed(let error):
            progress = 0
            isPreparing = false
            isReady = false
            failedMessage = error
        case .cancelled:
            progress = 0
            isPreparing = false
            isReady = false
            failedMessage = nil
        }

        let needsTail = await orchestrator.streamTargetNeedsTailProbe()
        let tailTotal = needsTail ? max(1, await orchestrator.streamTailPieceCount()) : 1
        let tailVerified = needsTail ? await orchestrator.streamTailPiecesVerified() : tailTotal

        return StreamRowBufferingMetrics(
            progress: progress,
            peerCount: peerCount,
            transferringPeerCount: transferringPeerCount,
            downloadSpeed: downloadSpeed,
            verifiedHeadBytes: await verifiedHeadBytes(),
            tailVerified: tailVerified,
            tailTotal: tailTotal,
            needsTailProbe: needsTail,
            indexProbeLabel: await orchestrator.streamIndexProbeLabel(),
            isReady: isReady,
            isPreparing: isPreparing,
            failedMessage: failedMessage
        )
    }
}

public extension StreamSession where O == StreamingOrchestrator {
    func fetchDiagnostics() async -> StreamDiagnosticsSnapshot {
        await orchestrator.diagnosticsSnapshot(
            torrent: activeTorrent,
            sessionState: state,
            swarmSeeders: swarmSeeders,
            swarmLeechers: swarmLeechers,
            livePeerCount: peerCount,
            liveDownloadSpeed: downloadSpeed,
            liveBufferedBytes: bufferedBytes,
            liveBufferedPieces: bufferedPieces,
            streamURL: activeStreamURL
        )
    }
}
```

---
## `App/CoreStreaming/Sources/CoreStreaming/HTTPRangeServer.swift`

```swift
import CoreStorage
import Foundation
import Network

// MARK: - HTTP Range Server

@MainActor
public final class HTTPRangeServer {
    public private(set) var port: UInt16 = 0
    public private(set) var isRunning = false

    private var listener: NWListener?
    private var pieceStore: PieceStore?
    private var pieceManager: PieceManager?
    private var streamByteOffset: Int64 = 0
    private var streamByteLength: Int64 = 0
    private var contentType = "application/octet-stream"

    public var onPlayerRead: (@Sendable (Int64, Int) async -> Void)?

    private static let maxRangeBytes = 2 * 1024 * 1024
    private static let readTimeoutSeconds: UInt64 = 300
    private static let bufferWaitSeconds: UInt64 = 300

    public init() {}

    /// Configures stream byte mapping without starting the TCP listener (unit tests).
    func configureForTests(
        pieceStore: PieceStore,
        streamTarget: TorrentStreamTarget,
        pieceManager: PieceManager? = nil
    ) {
        self.pieceStore = pieceStore
        self.pieceManager = pieceManager
        streamByteOffset = streamTarget.byteOffset
        streamByteLength = streamTarget.byteLength
        contentType = streamTarget.contentType
    }

    public func start(
        pieceStore: PieceStore,
        streamTarget: TorrentStreamTarget,
        pieceManager: PieceManager? = nil,
        preferredPort: UInt16 = 0
    ) async throws -> URL {
        self.pieceStore = pieceStore
        self.pieceManager = pieceManager
        self.streamByteOffset = streamTarget.byteOffset
        self.streamByteLength = streamTarget.byteLength
        self.contentType = streamTarget.contentType

        let parameters = NWParameters.tcp
        let nwPort: NWEndpoint.Port
        if preferredPort > 0, let port = NWEndpoint.Port(rawValue: preferredPort) {
            nwPort = port
        } else {
            nwPort = NWEndpoint.Port.any
        }
        listener = try NWListener(using: parameters, on: nwPort)

        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    self?.isRunning = true
                case .failed(let error):
                    self?.isRunning = false
                    TorrentLog.warn("[HTTPRangeServer] Listener failed: \(error)")
                case .cancelled:
                    self?.isRunning = false
                default:
                    break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { @MainActor in
                await self.handleConnection(connection)
            }
        }

        listener?.start(queue: .main)

        try await Task.sleep(for: .milliseconds(500))
        guard let port = listener?.port else {
            throw HTTPRangeServerError.failedToStart
        }
        self.port = port.rawValue
        guard let url = URL(string: "http://127.0.0.1:\(port)/stream") else {
            throw HTTPRangeServerError.failedToStart
        }
        TorrentLog.info(
            "[HTTPRangeServer] listening on port \(port.rawValue) — \(MovieBoxFileLogger.redactURL(url)) length=\(self.streamByteLength) offset=\(self.streamByteOffset)"
        )
        return url
    }

    public func stop() async {
        isRunning = false
        listener?.cancel()
        listener = nil
        pieceStore = nil
        pieceManager = nil
        onPlayerRead = nil
    }

    private func handleConnection(_ connection: NWConnection) async {
        guard let pieceStore else {
            connection.cancel()
            return
        }

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            if case .ready = state {
                connection.stateUpdateHandler = nil
                Task { @MainActor [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.receiveHTTPRequest(connection: connection, pieceStore: pieceStore)
                }
            }
        }
        connection.start(queue: .main)
    }

    private static let maxRequestHeaderBytes = 64 * 1024

    private func receiveHTTPRequest(connection: NWConnection, pieceStore: PieceStore, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                TorrentLog.debug("[HTTPRangeServer] Receive error: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            var requestBuffer = buffer
            if let data, !data.isEmpty {
                requestBuffer.append(data)
            }

            // SECURITY: Cap the accumulation buffer to prevent a local process flooding
            // the socket and growing this Data object without bound.
            if requestBuffer.count > Self.maxRequestHeaderBytes {
                TorrentLog.warn("[HTTPRangeServer] Request header too large (\(requestBuffer.count) bytes) — dropping connection")
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
                    connection.stateUpdateHandler = nil
                }
                connection.stateUpdateHandler = { [weak connection] state in
                    switch state {
                    case .cancelled, .failed:
                        responseTask.cancel()
                        connection?.stateUpdateHandler = nil
                    default:
                        break
                    }
                }
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection else { return }
                self.receiveHTTPRequest(connection: connection, pieceStore: pieceStore, buffer: requestBuffer)
            }
        }
    }

    func handleRequest(_ request: String, pieceStore: PieceStore) async -> HTTPResponse {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return HTTPResponse(status: 400, body: "Bad Request")
        }

        // SECURITY: DNS rebinding protection.
        // A web page could bind its domain to 127.0.0.1:PORT and read torrent bytes via
        // JavaScript fetch(). Reject any request whose Host header is not the loopback address.
        let hostHeader = lines
            .first { $0.lowercased().hasPrefix("host:") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces).lowercased() }
        // Accept 127.0.0.1, 127.0.0.1:PORT, localhost, localhost:PORT, and empty (direct connections).
        let allowedHosts: Set<String> = ["127.0.0.1", "localhost", ""]
        let bareHost = hostHeader.map { $0.components(separatedBy: ":").first ?? $0 } ?? ""
        guard allowedHosts.contains(bareHost) else {
            TorrentLog.warn("[HTTPRangeServer] Rejected request with non-loopback Host: \(hostHeader ?? "<nil>")")
            return HTTPResponse(status: 403, body: "Forbidden")
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            return HTTPResponse(status: 400, body: "Bad Request")
        }
        let method = parts[0].uppercased()
        guard method == "GET" || method == "HEAD" else {
            return HTTPResponse(status: 405, body: "Method Not Allowed")
        }

        let mediaLength = streamByteLength

        var statusCode = 200
        var bodyData = Data()
        var contentRange: String?
        var contentLength = mediaLength

        if let rangeHeader = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            let rangeParts = rangeHeader.components(separatedBy: "=")
            if rangeParts.count == 2 {
                let byteRange = rangeParts[1]
                let rangeComponents = byteRange.components(separatedBy: "-")
                let startStr = rangeComponents.first ?? ""
                let endStr = rangeComponents.count > 1 ? rangeComponents[1] : ""

                let mediaStart: Int64
                let mediaEnd: Int64
                let isSuffixRange: Bool
                if startStr.isEmpty, !endStr.isEmpty, let suffixLength = Int64(endStr) {
                    isSuffixRange = true
                    // Suffix range: bytes=-500 (common for end-of-file index probes).
                    let clampedSuffix = min(suffixLength, mediaLength)
                    mediaStart = max(0, mediaLength - clampedSuffix)
                    mediaEnd = mediaLength - 1
                } else if let parsedStart = Int64(startStr) {
                    isSuffixRange = false
                    mediaStart = parsedStart
                    if !endStr.isEmpty, let parsedEnd = Int64(endStr) {
                        mediaEnd = min(parsedEnd, mediaLength - 1)
                    } else {
                        mediaEnd = mediaLength - 1
                    }
                } else {
                    isSuffixRange = false
                    mediaStart = -1
                    mediaEnd = -1
                }

                if mediaStart >= 0 {
                    guard mediaStart < mediaLength, mediaEnd >= mediaStart else {
                        return HTTPResponse(status: 416, body: "Range Not Satisfiable")
                    }

                    // AVPlayer often sends open-ended ranges (e.g. bytes=0-). Cap the span
                    // instead of 416 — oversized ranges surface as "unknown error" in AVFoundation.
                    let maxSpan = Int64(Self.maxRangeBytes)
                    var cappedEnd = mediaEnd
                    if cappedEnd - mediaStart + 1 > maxSpan {
                        cappedEnd = mediaStart + maxSpan - 1
                    }

                    let span = cappedEnd &- mediaStart
                    let spanPlusOne = span &+ 1
                    guard spanPlusOne > 0 else {
                        return HTTPResponse(status: 416, body: "Range Not Satisfiable")
                    }
                    var length = Int(spanPlusOne)
                    length = min(length, Self.maxRangeBytes)
                    let rangeTorrentOffset = streamByteOffset + mediaStart

                    await notifyPlayerRead(mediaOffset: mediaStart, length: length)

                    guard let span = await waitForReadableSpan(
                        pieceStore: pieceStore,
                        offset: rangeTorrentOffset,
                        length: length,
                        preferSuffix: isSuffixRange
                    ) else {
                        TorrentLog.warn(
                            "[HTTPRangeServer] No readable bytes for range \(mediaStart)-\(mediaEnd) (suffix=\(isSuffixRange)) after \(Self.bufferWaitSeconds)s"
                        )
                        return HTTPResponse(status: 503, body: "Buffering", retryAfterSeconds: 1)
                    }

                    let torrentOffset = span.offset
                    let serveLength = span.length

                    do {
                        bodyData = try await readBytes(
                            pieceStore: pieceStore,
                            offset: torrentOffset,
                            length: serveLength
                        )
                        guard bodyData.count == serveLength else {
                            TorrentLog.warn(
                                "[HTTPRangeServer] Short read \(bodyData.count)/\(serveLength) at \(mediaStart) — still buffering"
                            )
                            return HTTPResponse(status: 503, body: "Buffering", retryAfterSeconds: 1)
                        }
                        let serveMediaStart = torrentOffset - streamByteOffset
                        let serveMediaEnd = serveMediaStart + Int64(bodyData.count) - 1
                        statusCode = 206
                        contentRange = "bytes \(serveMediaStart)-\(serveMediaEnd)/\(mediaLength)"
                        contentLength = Int64(bodyData.count)
                    } catch is CancellationError {
                        return HTTPResponse(status: 499, body: "Client Closed Request")
                    } catch is HTTPRangeReadTimeout {
                        TorrentLog.warn(
                            "[HTTPRangeServer] Range \(mediaStart)-\(mediaEnd) timed out after \(Self.readTimeoutSeconds)s — still buffering"
                        )
                        return HTTPResponse(status: 503, body: "Buffering", retryAfterSeconds: 2)
                    } catch let error as PieceStoreError {
                        if case .readTimeout = error {
                            TorrentLog.warn(
                                "[HTTPRangeServer] PieceStore read timeout at \(mediaStart) — still buffering"
                            )
                            return HTTPResponse(status: 503, body: "Buffering", retryAfterSeconds: 2)
                        } else {
                            TorrentLog.warn("[HTTPRangeServer] Range read failed: \(error.localizedDescription)")
                            return HTTPResponse(status: 500, body: "Internal Server Error")
                        }
                    } catch {
                        TorrentLog.warn("[HTTPRangeServer] Range read failed: \(error.localizedDescription)")
                        return HTTPResponse(status: 500, body: "Internal Server Error")
                    }
                }
            }
        } else if method == "GET" {
            let length = min(512 * 1024, Int(mediaLength))
            await notifyPlayerRead(mediaOffset: 0, length: length)
            guard let span = await waitForReadableSpan(
                pieceStore: pieceStore,
                offset: streamByteOffset,
                length: length,
                preferSuffix: false
            ) else {
                return HTTPResponse(status: 503, body: "Buffering", retryAfterSeconds: 1)
            }
            do {
                bodyData = try await readBytes(
                    pieceStore: pieceStore,
                    offset: span.offset,
                    length: span.length
                )
                guard bodyData.count == span.length else {
                    return HTTPResponse(status: 503, body: "Buffering", retryAfterSeconds: 1)
                }
                contentLength = Int64(bodyData.count)
            } catch is CancellationError {
                return HTTPResponse(status: 499, body: "Client Closed Request")
            } catch is HTTPRangeReadTimeout {
                return HTTPResponse(status: 503, body: "Buffering", retryAfterSeconds: 1)
            } catch let error as PieceStoreError {
                if case .readTimeout = error {
                    return HTTPResponse(status: 503, body: "Buffering", retryAfterSeconds: 1)
                } else {
                    return HTTPResponse(status: 500, body: "Internal Server Error")
                }
            } catch {
                return HTTPResponse(status: 500, body: "Internal Server Error")
            }
        } else {
            contentLength = mediaLength
        }

        var headers = [
            "HTTP/1.1 \(statusCode) \(HTTPResponse.statusMessage(for: statusCode))",
            "Content-Type: \(contentType)",
            "Content-Length: \(contentLength)",
            "Accept-Ranges: bytes",
            "Connection: close",
        ]
        if let contentRange {
            headers.append("Content-Range: \(contentRange)")
        }

        let headerString = headers.joined(separator: "\r\n") + "\r\n\r\n"
        guard let headerData = headerString.data(using: .utf8) else {
            return HTTPResponse(status: 500, body: "Internal Server Error")
        }
        var response = Data()
        response.append(headerData)
        if method == "GET" {
            response.append(bodyData)
        }

        return HTTPResponse(status: statusCode, data: response, retryAfterSeconds: nil)
    }

    private func notifyPlayerRead(mediaOffset: Int64, length: Int) async {
        await pieceManager?.notePlayerRead(mediaOffset: mediaOffset, length: length)
        await onPlayerRead?(mediaOffset, length)
    }

    private func waitForReadableSpan(
        pieceStore: PieceStore,
        offset: Int64,
        length: Int,
        preferSuffix: Bool
    ) async -> (offset: Int64, length: Int)? {
        let attempts = Int(Self.bufferWaitSeconds * 10)
        for attempt in 0..<attempts {
            if Task.isCancelled {
                return nil
            }
            if let span = await pieceStore.readableSpan(
                offset: offset,
                length: length,
                preferSuffix: preferSuffix
            ) {
                if attempt > 0 {
                    TorrentLog.info(
                        "[HTTPRangeServer] Range ready after \(attempt * 100)ms — \(span.length) B @ \(span.offset) suffix=\(preferSuffix)"
                    )
                }
                return span
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return nil
            }
        }
        return nil
    }

    private func readBytes(pieceStore: PieceStore, offset: Int64, length: Int) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await pieceStore.read(offset: offset, length: length)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.readTimeoutSeconds))
                throw HTTPRangeReadTimeout()
            }
            guard let data = try await group.next() else {
                throw HTTPRangeReadTimeout()
            }
            group.cancelAll()
            return data
        }
    }

    private func sendResponse(connection: NWConnection, response: HTTPResponse) {
        connection.send(content: response.data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private struct HTTPRangeReadTimeout: Error {}

struct HTTPResponse {
    let status: Int
    let data: Data

    init(status: Int, body: String, retryAfterSeconds: Int? = nil) {
        self.status = status
        var headerLines = [
            "HTTP/1.1 \(status) \(HTTPResponse.statusMessage(for: status))",
            "Content-Length: \(body.count)",
            "Content-Type: text/plain",
            "Connection: close",
        ]
        if let retryAfterSeconds {
            headerLines.append("Retry-After: \(retryAfterSeconds)")
        }
        let raw = headerLines.joined(separator: "\r\n") + "\r\n\r\n" + body
        self.data = raw.data(using: .utf8) ?? Data()
    }

    init(status: Int, data: Data, retryAfterSeconds: Int? = nil) {
        self.status = status
        self.data = data
    }

    static func statusMessage(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        case 503: "Service Unavailable"
        case 500: "Internal Server Error"
        default: "Unknown"
        }
    }
}

public enum HTTPRangeServerError: Error, LocalizedError {
    case failedToStart

    public var errorDescription: String? {
        "Failed to start HTTP range server"
    }
}
```

---
## `App/CoreStreaming/Sources/CoreStreaming/TorrentStreamTarget.swift`

```swift
import Foundation

/// Identifies which file inside a multi-file torrent is streamed to the player.
public struct TorrentStreamTarget: Sendable {
    public let file: TorrentFile
    /// Byte offset of this file within the torrent's piece-addressable layout.
    public let byteOffset: Int64
    public let byteLength: Int64
    public let firstPieceIndex: Int
    /// Last torrent piece overlapping the streamed file (often needed for MKV index/cues).
    public let lastPieceIndex: Int
    public let contentType: String

    public init(
        file: TorrentFile,
        byteOffset: Int64,
        byteLength: Int64,
        firstPieceIndex: Int,
        lastPieceIndex: Int,
        contentType: String
    ) {
        self.file = file
        self.byteOffset = byteOffset
        self.byteLength = byteLength
        self.firstPieceIndex = firstPieceIndex
        self.lastPieceIndex = lastPieceIndex
        self.contentType = contentType
    }

    /// AVPlayer probes the end of the file for container indexes (MKV cues, MP4 `moov`, etc.).
    public var needsTailProbeForPlayback: Bool {
        let ext = file.relativePath.lowercased()
        if ext.hasSuffix(".mkv") { return true }
        if ext.hasSuffix(".mp4") || ext.hasSuffix(".m4v") || ext.hasSuffix(".mov") { return true }
        if ext.hasSuffix(".webm") { return true }
        return contentType.contains("matroska")
    }

    /// Containers where readiness requires a complete MP4 `moov` atom in the tail window.
    public var needsMP4MoovTailProbe: Bool {
        let ext = (file.relativePath as NSString).pathExtension.lowercased()
        if ext == "mp4" || ext == "m4v" || ext == "mov" { return true }
        return contentType.contains("mp4") || contentType.contains("quicktime")
    }

    public static func selectPrimary(from metadata: TorrentMetadata) -> TorrentStreamTarget {
        let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "avi", "mov", "webm", "ts", "m2ts"]

        let videoCandidates = metadata.files.filter { file in
            let ext = (file.relativePath as NSString).pathExtension.lowercased()
            return videoExtensions.contains(ext)
        }

        let chosen: TorrentFile
        if let largestVideo = videoCandidates.max(by: { $0.length < $1.length }) {
            chosen = largestVideo
        } else if let largestFile = metadata.files.max(by: { $0.length < $1.length }) {
            chosen = largestFile
        } else {
            chosen = metadata.files[0]
        }

        var offset: Int64 = 0
        for file in metadata.files {
            if file.relativePath == chosen.relativePath { break }
            offset += file.length
        }

        let firstPiece = Int(offset / metadata.pieceLength)
        let lastByte = offset + chosen.length - 1
        let lastPiece = Int(lastByte / metadata.pieceLength)
        let ext = (chosen.relativePath as NSString).pathExtension.lowercased()
        let mime: String
        switch ext {
        case "mkv": mime = "video/x-matroska"
        case "webm": mime = "video/webm"
        case "mov", "m4v": mime = "video/quicktime"
        default: mime = "video/mp4"
        }

        return TorrentStreamTarget(
            file: chosen,
            byteOffset: offset,
            byteLength: chosen.length,
            firstPieceIndex: firstPiece,
            lastPieceIndex: lastPiece,
            contentType: mime
        )
    }
}
```

---
## `App/CoreStreaming/Sources/CoreStreaming/TorrentMetadata.swift`

```swift
import Foundation
import CryptoKit

// MARK: - Magnet URI Parser

public struct MagnetURI: Sendable, Hashable {
    public let infoHash: String
    public let displayName: String?
    public let trackers: [String]

    public init(infoHash: String, displayName: String? = nil, trackers: [String] = []) {
        self.infoHash = infoHash
        self.displayName = displayName
        self.trackers = trackers
    }

    public init?(from magnetURI: String) {
        guard magnetURI.hasPrefix("magnet:?") else { return nil }

        let query = String(magnetURI.dropFirst(8))
        var rawInfoHash: String?
        var displayName: String?
        var trackers: [String] = []

        let pairs = query.components(separatedBy: "&")
        for pair in pairs {
            let parts = pair.components(separatedBy: "=")
            guard parts.count == 2 else { continue }

            let key = parts[0]
            let value = parts[1].removingPercentEncoding ?? parts[1]

            switch key {
            case "xt":
                if value.hasPrefix("urn:btih:") {
                    rawInfoHash = String(value.dropFirst(9)).lowercased()
                }
            case "dn":
                displayName = value
            case "tr":
                trackers.append(value)
            default:
                break
            }
        }

        guard let rawHash = rawInfoHash else { return nil }

        let finalHash: String
        if rawHash.count == 40 {
            finalHash = rawHash
        } else if rawHash.count == 32, let decoded = Self.decodeBase32(rawHash) {
            finalHash = decoded
        } else {
            return nil
        }

        self.infoHash = finalHash
        self.displayName = displayName
        self.trackers = trackers
    }

    private static func decodeBase32(_ input: String) -> String? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var bits = ""

        for char in input.uppercased() {
            guard let index = alphabet.firstIndex(of: char) else { continue }
            let value = alphabet.distance(from: alphabet.startIndex, to: index)
            bits += String(value, radix: 2).paddingToLeft(5)
        }

        var hexBytes = ""
        while bits.count >= 8 {
            let byte = String(bits.prefix(8))
            bits = String(bits.dropFirst(8))
            if let value = UInt8(byte, radix: 2) {
                hexBytes += String(format: "%02x", value)
            }
        }

        return hexBytes.isEmpty ? nil : hexBytes
    }
}

private extension String {
    func paddingToLeft(_ length: Int) -> String {
        if count >= length { return self }
        return String(repeating: "0", count: length - count) + self
    }
}

// MARK: - Torrent Metadata

public struct TorrentMetadata: Sendable {
    public let infoHash: String
    public let name: String
    public let totalSize: Int64
    public let pieceLength: Int64
    public let pieceCount: Int
    public let pieces: Data
    public let files: [TorrentFile]
    public let trackers: [String]

    public init(
        infoHash: String,
        name: String,
        totalSize: Int64,
        pieceLength: Int64,
        pieces: Data,
        files: [TorrentFile],
        trackers: [String] = []
    ) {
        self.infoHash = infoHash
        self.name = name
        self.totalSize = totalSize
        self.pieceLength = pieceLength
        self.pieceCount = Int((totalSize + pieceLength - 1) / pieceLength)
        self.pieces = pieces
        self.files = files
        self.trackers = trackers
    }
}

public struct TorrentFile: Sendable {
    public let path: [String]
    public let length: Int64

    public var relativePath: String {
        path.joined(separator: "/")
    }
}

// MARK: - Torrent File Parser

public enum TorrentFileParser {
    /// Parses a bencoded `info` dictionary (from `ut_metadata` or similar).
    public static func parse(
        infoBencoded: Data,
        expectedInfoHash: String,
        trackers: [String]
    ) throws -> TorrentMetadata {
        guard infoBencoded.sha1Hex == expectedInfoHash.lowercased() else {
            throw TorrentMetadataFetcher.FetchError.infoHashMismatch
        }
        guard let infoDict = try BencodeParser.parse(infoBencoded).dictionary else {
            throw TorrentParserError.invalidFormat
        }
        return try metadata(from: infoDict, infoHash: expectedInfoHash.lowercased(), trackers: trackers)
    }

    public static func parse(data: Data) throws -> TorrentMetadata {
        let bencode = try BencodeParser.parse(data)
        guard let dict = bencode.dictionary else {
            throw TorrentParserError.invalidFormat
        }

        guard let infoDict = dict["info"]?.dictionary else {
            throw TorrentParserError.missingInfo
        }

        let infoData = try extractInfoData(from: data)
        let infoHash = infoData.sha1Hex

        var mergedTrackers: [String] = []
        if case .string(let trackerData) = dict["announce"] {
            if let tracker = String(data: trackerData, encoding: .utf8) {
                mergedTrackers.append(tracker)
            }
        }
        if let announceList = dict["announce-list"]?.list {
            for tier in announceList {
                if let tierList = tier.list {
                    for tracker in tierList {
                        if case .string(let trackerData) = tracker,
                           let trackerString = String(data: trackerData, encoding: .utf8) {
                            mergedTrackers.append(trackerString)
                        }
                    }
                }
            }
        }

        return try metadata(from: infoDict, infoHash: infoHash, trackers: mergedTrackers)
    }

    private static func metadata(
        from infoDict: [String: BencodeValue],
        infoHash: String,
        trackers: [String]
    ) throws -> TorrentMetadata {
        let name: String
        if let nameValue = infoDict["name"]?.string {
            name = nameValue
        } else {
            name = "Unknown"
        }

        let pieceLength = infoDict["piece length"]?.integer ?? 0
        let pieces = infoDict["pieces"]
        let piecesData: Data
        if case .string(let data) = pieces {
            piecesData = data
        } else {
            throw TorrentParserError.missingPieces
        }

        var files: [TorrentFile] = []
        if let length = infoDict["length"]?.integer {
            files.append(TorrentFile(path: [name], length: length))
        } else if let fileArray = infoDict["files"]?.list {
            for fileValue in fileArray {
                guard let fileDict = fileValue.dictionary,
                      let length = fileDict["length"]?.integer,
                      let pathList = fileDict["path"]?.list else { continue }
                let pathComponents = pathList.compactMap { $0.string }
                files.append(TorrentFile(path: [name] + pathComponents, length: length))
            }
        }

        let totalSize = files.reduce(0) { $0 + $1.length }

        return TorrentMetadata(
            infoHash: infoHash,
            name: name,
            totalSize: totalSize,
            pieceLength: pieceLength,
            pieces: piecesData,
            files: files,
            trackers: trackers
        )
    }

    private static func extractInfoData(from data: Data) throws -> Data {
        var index = data.startIndex
        guard data[index] == UInt8(ascii: "d") else {
            throw TorrentParserError.invalidFormat
        }
        index += 1

        while index < data.endIndex {
            if data[index] == UInt8(ascii: "e") {
                break
            }

            var lengthEnd = index
            while lengthEnd < data.endIndex, data[lengthEnd] != UInt8(ascii: ":") {
                lengthEnd += 1
            }
            guard lengthEnd < data.endIndex else {
                throw TorrentParserError.invalidFormat
            }

            let lengthData = data[index..<lengthEnd]
            guard let lengthString = String(data: lengthData, encoding: .ascii),
                  let length = Int(lengthString) else {
                throw TorrentParserError.invalidFormat
            }

            let keyStart = lengthEnd + 1
            let keyEnd = keyStart + length
            guard keyEnd <= data.endIndex else {
                throw TorrentParserError.invalidFormat
            }

            let keyData = data[keyStart..<keyEnd]
            if let key = String(data: keyData, encoding: .utf8), key == "info" {
                let valueStart = keyEnd
                var valueIndex = valueStart
                _ = try skipBencodeValue(data, at: &valueIndex)
                return data[valueStart..<valueIndex]
            }

            index = keyEnd
            _ = try skipBencodeValue(data, at: &index)
        }

        throw TorrentParserError.missingInfo
    }

    private static func skipBencodeValue(_ data: Data, at index: inout Data.Index) throws -> Data.Index {
        guard index < data.endIndex else {
            throw TorrentParserError.invalidFormat
        }

        switch data[index] {
        case UInt8(ascii: "i"):
            index += 1
            while index < data.endIndex, data[index] != UInt8(ascii: "e") {
                index += 1
            }
            index += 1
        case UInt8(ascii: "l"), UInt8(ascii: "d"):
            index += 1
            while index < data.endIndex, data[index] != UInt8(ascii: "e") {
                _ = try skipBencodeValue(data, at: &index)
            }
            index += 1
        case let b where b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"):
            var lengthEnd = index
            while lengthEnd < data.endIndex, data[lengthEnd] != UInt8(ascii: ":") {
                lengthEnd += 1
            }
            guard lengthEnd < data.endIndex else {
                throw TorrentParserError.invalidFormat
            }
            let lengthData = data[index..<lengthEnd]
            guard let lengthString = String(data: lengthData, encoding: .ascii),
                  let length = Int(lengthString) else {
                throw TorrentParserError.invalidFormat
            }
            index = lengthEnd + 1 + length
        default:
            throw TorrentParserError.invalidFormat
        }

        return index
    }
}

extension TorrentMetadata {
    /// Builds a magnet URI suitable for `MagnetURI` and the Downloads import UI.
    public var magnetURI: String {
        var components = ["magnet:?xt=urn:btih:\(infoHash)"]
        if let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            components.append("dn=\(encodedName)")
        }
        for tracker in trackers.prefix(8) {
            if let encoded = tracker.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                components.append("tr=\(encoded)")
            }
        }
        return components.joined(separator: "&")
    }
}

public enum TorrentParserError: Error, LocalizedError {
    case invalidFormat
    case missingInfo
    case missingPieces

    public var errorDescription: String? {
        switch self {
        case .invalidFormat: "Invalid torrent file format"
        case .missingInfo: "Missing 'info' dictionary in torrent file"
        case .missingPieces: "Missing 'pieces' data in torrent info"
        }
    }
}

// MARK: - SHA1 Helper

private extension Data {
    var sha1Hex: String {
        let hash = Insecure.SHA1.hash(data: self)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
```

---
## `App/CoreStreaming/Sources/CoreStreaming/StreamPlaybackThreshold.swift`

```swift
import Foundation

public enum StreamPlaybackThreshold {
  /// Minimum contiguous bytes at the media head before the UI may start AVPlayer.
  public static let minimumHeadBytes: Int64 = 192 * 1024
}
```

