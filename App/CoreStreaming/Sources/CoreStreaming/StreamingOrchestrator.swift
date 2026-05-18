import Foundation
import CoreTorrent

// MARK: - Streaming Orchestrator

@MainActor
public final class StreamingOrchestrator {
    private var pieceStore: PieceStore?
    private var pieceManager: PieceManager?
    private var rangeServer = HTTPRangeServer()
    private var torrentEngine: TorrentEngine?
    private var metadata: TorrentMetadata?
    private var peerId: String = ""
    private var dht: KademliaDHT?
    private var udpTrackerClient = UDPTrackerClient()

    public init() {}

    public func startStream(
        torrent: TorrentResult,
        progressHandler: @escaping @Sendable (Double, Double, Int) -> Void
    ) async throws -> URL {
        peerId = BitTorrentPeerID.make()

        let magnet = MagnetURI(from: torrent.magnetURI)
        let infoHash = torrent.infoHash ?? magnet?.infoHash
        guard let infoHash, !infoHash.isEmpty else {
            throw StreamingOrchestratorError.invalidMagnetURI
        }

        do {
            metadata = try await TorrentMetadataFetcher.fetch(
                infoHash: infoHash,
                magnetTrackers: magnet?.trackers ?? []
            )
        } catch {
            throw StreamingOrchestratorError.metadataUnavailable(error.localizedDescription)
        }

        guard let metadata else {
            throw StreamingOrchestratorError.failedToInitialize
        }

        pieceStore = try await PieceStore(
            infoHash: metadata.infoHash,
            pieceCount: metadata.pieceCount,
            pieceSize: metadata.pieceLength,
            storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("moviebox_streams")
        )

        pieceManager = PieceManager(
            pieceCount: metadata.pieceCount,
            pieceLength: metadata.pieceLength,
            totalSize: metadata.totalSize,
            piecesHash: metadata.pieces
        )

        torrentEngine = TorrentEngine(
            metadata: metadata,
            pieceManager: pieceManager!,
            pieceStore: pieceStore!,
            peerId: peerId,
            progressHandler: progressHandler
        )

        await torrentEngine?.start()

        let streamURL = try await rangeServer.start(pieceStore: pieceStore!)
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
        dht?.stop()
        dht = nil
    }

    public func progress() async -> Double {
        await pieceStore?.progress() ?? 0
    }

    public func contiguousPiecesFromStart() async -> Int {
        await pieceStore?.contiguousPiecesFromStart() ?? 0
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

// MARK: - Real Torrent Engine

@MainActor
public final class TorrentEngine {
    public var downloadSpeed: Double = 0
    public var activePeerCount: Int = 0

    private let metadata: TorrentMetadata
    private let pieceManager: PieceManager
    private let pieceStore: PieceStore
    private let peerId: String
    private let progressHandler: @Sendable (Double, Double, Int) -> Void
    private var trackerClient = TrackerClient()
    private var udpTrackerClient = UDPTrackerClient()
    private var dht: KademliaDHT?
    private var peerConnections: [PeerConnection] = []
    private var isRunning = false
    private var announceTimer: Task<Void, Never>?
    private var statsTimer: Task<Void, Never>?
    private var bytesDownloaded: Int64 = 0
    private var downloadStartTime: Date?

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
        downloadStartTime = Date.now

        Task {
            await announceToTrackers()
        }

        startAnnounceTimer()

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
        dht?.stop()
        dht = nil

        for peer in peerConnections {
            peer.disconnect()
        }
        peerConnections.removeAll()
    }

    private func announceToTrackers() async {
        let trackerList = metadata.trackers
        NSLog("[TorrentEngine] 📣 Announcing to \(trackerList.count) trackers in parallel...")

        let peersFound = await withTaskGroup(of: [PeerInfo].self) { group in
            for tracker in trackerList {
                group.addTask { [self] in
                    if tracker.hasPrefix("udp://") {
                        do {
                            let response = try await udpTrackerClient.announce(
                                trackerURL: tracker,
                                infoHash: metadata.infoHash,
                                peerId: peerId,
                                port: 6881,
                                downloaded: bytesDownloaded,
                                left: metadata.totalSize - bytesDownloaded,
                                event: .started
                            )
                            NSLog("[TorrentEngine] 🟢 UDP tracker announce succeeded: \(tracker) (found \(response.peers.count) peers)")
                            return response.peers
                        } catch {
                            NSLog("[TorrentEngine] 🔴 UDP tracker failed: \(tracker) - \(error.localizedDescription)")
                            return []
                        }
                    } else {
                        do {
                            let response = try await trackerClient.announce(
                                trackerURL: tracker,
                                infoHash: metadata.infoHash,
                                peerId: peerId,
                                port: 6881,
                                downloaded: bytesDownloaded,
                                left: metadata.totalSize - bytesDownloaded,
                                event: .started
                            )
                            NSLog("[TorrentEngine] 🟢 HTTP tracker announce succeeded: \(tracker) (found \(response.peers.count) peers)")
                            return response.peers
                        } catch {
                            NSLog("[TorrentEngine] 🔴 HTTP tracker failed: \(tracker) - \(error.localizedDescription)")
                            return []
                        }
                    }
                }
            }

            var mergedPeers: [PeerInfo] = []
            var seen = Set<String>()
            for await peers in group {
                for peer in peers {
                    let key = "\(peer.ip):\(peer.port)"
                    if seen.insert(key).inserted {
                        mergedPeers.append(peer)
                    }
                }
            }
            return mergedPeers
        }

        var finalPeers = peersFound
        NSLog("[TorrentEngine] 📊 Found \(finalPeers.count) unique peers from trackers.")

        if finalPeers.isEmpty {
            NSLog("[TorrentEngine] ⚠️ No peers found from trackers, falling back to DHT...")
            await startDHT()
            let dhtPeers = await dht?.findPeers(infoHash: metadata.infoHash) ?? []
            NSLog("[TorrentEngine] 📊 Found \(dhtPeers.count) peers from DHT.")
            for peer in dhtPeers {
                let key = "\(peer.ip):\(peer.port)"
                if !finalPeers.contains(where: { "\($0.ip):\($0.port)" == key }) {
                    finalPeers.append(peer)
                }
            }
        }

        if !finalPeers.isEmpty {
            NSLog("[TorrentEngine] 🌐 Initiating connection attempts to the first \(min(30, finalPeers.count)) peers...")
            await connectToPeers(finalPeers)
        } else {
            NSLog("[TorrentEngine] ❌ No peers found from trackers or DHT. Waiting for announce retry...")
        }
    }

    private func startAnnounceTimer() {
        announceTimer = Task {
            while !Task.isCancelled && isRunning {
                try? await Task.sleep(for: .seconds(60))
                if isRunning {
                    var newPeers: [PeerInfo] = []

                    for tracker in metadata.trackers {
                        if tracker.hasPrefix("udp://") {
                            if let response = try? await udpTrackerClient.announce(
                                trackerURL: tracker,
                                infoHash: metadata.infoHash,
                                peerId: peerId,
                                port: 6881,
                                downloaded: bytesDownloaded,
                                left: metadata.totalSize - bytesDownloaded,
                                event: .empty
                            ) {
                                newPeers.append(contentsOf: response.peers)
                            }
                        } else {
                            if let response = try? await trackerClient.announce(
                                trackerURL: tracker,
                                infoHash: metadata.infoHash,
                                peerId: peerId,
                                port: 6881,
                                downloaded: bytesDownloaded,
                                left: metadata.totalSize - bytesDownloaded,
                                event: .empty
                            ) {
                                newPeers.append(contentsOf: response.peers)
                            }
                        }
                    }

                    if newPeers.isEmpty, let dhtPeers = await dht?.findPeers(infoHash: metadata.infoHash) {
                        newPeers.append(contentsOf: dhtPeers)
                    }

                    if !newPeers.isEmpty {
                        await connectToPeers(newPeers)
                    }
                }
            }
        }
    }

    private func startDHT() async {
        guard dht == nil else { return }

        let dht = KademliaDHT()
        self.dht = dht

        do {
            try await dht.start(port: 6882)
            NSLog("DHT started on port 6882")
            await dht.announce(infoHash: metadata.infoHash, port: 6881)
        } catch {
            NSLog("DHT failed to start: \(error)")
            self.dht = nil
        }
    }

    private func connectToPeers(_ peers: [PeerInfo]) async {
        for peerInfo in peers.prefix(30) {
            guard isRunning else { return }

            let connection = PeerConnection(peerInfo: peerInfo, connectionPeerId: peerId)
            peerConnections.append(connection)

            Task {
                await connection.connect(
                    infoHash: metadata.infoHash,
                    pieceManager: pieceManager,
                    onPieceReceived: { [weak self] pieceIndex, offset, block in
                        Task { @MainActor in
                            await self?.handlePieceReceived(pieceIndex: pieceIndex, offset: offset, block: block)
                        }
                    }
                )
            }
        }
    }

    private func handlePieceReceived(pieceIndex: UInt32, offset: UInt32, block: Data) async {
        let pieceComplete = await pieceManager.markBlockReceived(
            pieceIndex: pieceIndex,
            offset: offset,
            block: block
        )

        bytesDownloaded += Int64(block.count)

        if pieceComplete, let pieceData = await pieceManager.getPieceData(pieceIndex) {
            do {
                try await pieceStore.write(pieceIndex: Int(pieceIndex), data: pieceData)
            } catch {
                NSLog("Failed to write piece \(pieceIndex): \(error)")
            }
        }

        let progress = await pieceManager.progress()
        let downloadedCount = await pieceManager.downloadedCount()

        let elapsed = downloadStartTime.map { Date.now.timeIntervalSince($0) } ?? 1
        let speed = elapsed > 0 ? Double(bytesDownloaded) / elapsed : 0

        downloadSpeed = speed
        activePeerCount = peerConnections.filter {
            switch $0.state {
            case .disconnected: return false
            case .error(_): return false
            default: return true
            }
        }.count

        progressHandler(progress, speed, activePeerCount)
    }

    private func updateStats() async {
        let progress = await pieceManager.progress()
        let elapsed = downloadStartTime.map { Date.now.timeIntervalSince($0) } ?? 1
        let speed = elapsed > 0 ? Double(bytesDownloaded) / elapsed : 0

        downloadSpeed = speed
        activePeerCount = peerConnections.filter {
            switch $0.state {
            case .disconnected, .error(_): return false
            default: return true
            }
        }.count

        progressHandler(progress, speed, activePeerCount)
    }
}
