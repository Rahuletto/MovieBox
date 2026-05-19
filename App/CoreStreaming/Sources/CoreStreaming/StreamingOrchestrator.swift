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
            metadata = try await TorrentMetadataFetcher.fetch(
                infoHash: infoHash,
                magnetTrackers: magnet?.trackers ?? []
            )
        } catch {
            TorrentLog.warn("[Streaming] metadata fetch failed — \(error.localizedDescription)")
            throw StreamingOrchestratorError.metadataUnavailable(error.localizedDescription)
        }

        guard let metadata else {
            throw StreamingOrchestratorError.failedToInitialize
        }

        try TorrentLimits.validateTotalSize(metadata.totalSize)

        let target = TorrentStreamTarget.selectPrimary(from: metadata)
        streamTarget = target
        TorrentLog.info("[Streaming] Target file: \(target.file.relativePath) (\(target.byteLength) bytes, piece \(target.firstPieceIndex)+)")

        pieceStore = try await PieceStore(
            infoHash: metadata.infoHash,
            pieceCount: metadata.pieceCount,
            pieceSize: metadata.pieceLength,
            totalSize: metadata.totalSize,
            streamFirstPiece: target.firstPieceIndex,
            streamMediaByteOffset: target.byteOffset,
            storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("moviebox_streams")
        )

        pieceManager = PieceManager(
            pieceCount: metadata.pieceCount,
            pieceLength: metadata.pieceLength,
            totalSize: metadata.totalSize,
            piecesHash: metadata.pieces,
            streamFirstPiece: target.firstPieceIndex
        )

        torrentEngine = TorrentEngine(
            metadata: metadata,
            pieceManager: pieceManager!,
            pieceStore: pieceStore!,
            peerId: peerId,
            progressHandler: progressHandler
        )

        await torrentEngine?.start()

        let streamURL = try await rangeServer.start(pieceStore: pieceStore!, streamTarget: target)
        TorrentLog.info(
            "[Streaming] HTTP range server — \(MovieBoxFileLogger.redactURL(streamURL)) type=\(target.contentType) mediaBytes=\(target.byteLength)"
        )
        return streamURL
    }

    public func stop() async {
        await torrentEngine?.stop()
        torrentEngine = nil
        await rangeServer.stop()
        await pieceStore?.cleanup()
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

    public func streamHeadContiguousBytes() async -> Int64 {
        await pieceStore?.streamHeadContiguousBytes() ?? 0
    }

    public func downloadSpeed() async -> Double {
        await torrentEngine?.downloadSpeed ?? 0
    }

    public func peerCount() async -> Int {
        await torrentEngine?.activePeerCount ?? 0
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
    private var connectedPeerKeys = Set<String>()
    private var isRunning = false
    private var announceTimer: Task<Void, Never>?
    private var statsTimer: Task<Void, Never>?
    private var maintenanceTimer: Task<Void, Never>?

    private var bytesDownloaded: Int64 = 0
    private var recentBytesSamples: [(date: Date, bytes: Int64)] = []

    private let maxPeerConnections = 36
    private let peersPerAnnounce = 20

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

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        Task { await announceToTrackers() }
        startAnnounceTimer()
        startMaintenanceTimer()

        statsTimer = Task {
            while !Task.isCancelled && isRunning {
                await updateStats()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stop() {
        isRunning = false
        announceTimer?.cancel()
        statsTimer?.cancel()
        maintenanceTimer?.cancel()
        dht?.stop()
        dht = nil

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

    private func fetchPeersFromTrackers(event: TrackerEvent) async -> [PeerInfo] {
        TorrentLog.info("[TorrentEngine] Announcing to \(metadata.trackers.count) trackers...")
        let eventCode = event.rawValue

        let peersFound = await withTaskGroup(of: [PeerInfo].self) { group in
            for tracker in metadata.trackers {
                let trackerURL = tracker
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
            for await peers in group {
                for peer in peers {
                    let key = peerKey(peer)
                    if seen.insert(key).inserted {
                        merged.append(peer)
                    }
                }
            }
            return merged
        }

        var finalPeers = peersFound
        if finalPeers.isEmpty {
            await startDHT()
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

    private func startAnnounceTimer() {
        announceTimer = Task {
            while !Task.isCancelled && isRunning {
                try? await Task.sleep(for: .seconds(60))
                guard isRunning else { return }
                let peers = await fetchPeersFromTrackers(event: .empty)
                await connectToPeers(peers)
            }
        }
    }

    private func startMaintenanceTimer() {
        maintenanceTimer = Task {
            while !Task.isCancelled && isRunning {
                try? await Task.sleep(for: .seconds(10))
                guard isRunning else { return }
                pruneDeadPeers()
                await expireStalledRequests()
            }
        }
    }

    private func startDHT() async {
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

            Task {
                await connection.connect(
                    infoHash: metadata.infoHash,
                    pieceManager: pieceManager,
                    onPieceReceived: { [weak self] pieceIndex, offset, block in
                        await self?.handlePieceReceived(pieceIndex: pieceIndex, offset: offset, block: block)
                    }
                )
            }
        }

        if connected > 0 {
            TorrentLog.debug("[TorrentEngine] Connecting to \(connected) new peers (\(peerConnections.count) total)")
        }
    }

    private func pruneDeadPeers() {
        let before = peerConnections.count
        peerConnections.removeAll { peer in
            switch peer.state {
            case .disconnected, .error:
                connectedPeerKeys.remove(peerKey(peer.peerInfo))
                return true
            default:
                return false
            }
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
        recordBytesSample()
        await publishProgress()
    }

    private func updateStats() async {
        recordBytesSample()
        await publishProgress()
    }

    private func publishProgress() async {
        let progress = await pieceManager.progress()
        downloadSpeed = recentDownloadSpeed()
        activePeerCount = peerConnections.filter { $0.isActive }.count
        progressHandler(progress, downloadSpeed, activePeerCount)
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
}
