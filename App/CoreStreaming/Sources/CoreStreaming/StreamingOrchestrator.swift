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
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)

        // Load existing bitmap if any (keyed by infoHash — same torrent reuses verified pieces)
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

        // Speculative pre-boost: immediately request the last 2 MB of the file
        // to make sure the moov region is downloading as early as possible.
        let tailOffset = max(0, target.byteLength - 2 * 1024 * 1024)
        await manager.notePlayerRead(mediaOffset: tailOffset, length: 2 * 1024 * 1024)
        await engine.refreshDownloadPriorities()

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
        await hasMinimumPlaybackHead()
    }

    public func hasMinimumPlaybackHead() async -> Bool {
        guard let pieceStore, let target = streamTarget else { return false }
        let verifiedHead = await pieceStore.verifiedMediaBytesFromStart()
        let threshold = minimumHeadBytes(for: target)
        let ready = verifiedHead >= threshold
        if ready {
            await pieceManager?.setIndexBootstrapCompleted()
        }
        return ready
    }

    private func minimumHeadBytes(for target: TorrentStreamTarget) -> Int64 {
        let ext = (target.file.relativePath as NSString).pathExtension.lowercased()
        if ext == "mkv" || ext == "webm" || target.contentType.contains("matroska") {
            return StreamPlaybackThreshold.minimumHeadBytesForMKV
        }
        return StreamPlaybackThreshold.minimumHeadBytes
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
