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
        peerId = Self.generatePeerId()

        let magnet = MagnetURI(from: torrent.magnetURI)
        guard let magnet else {
            throw StreamingOrchestratorError.invalidMagnetURI
        }

        let pieceSize: Int64 = 256 * 1024
        let estimatedPieces = max(1, Int((torrent.sizeBytes + pieceSize - 1) / pieceSize))

        let piecesHash = Data(count: estimatedPieces * 20)

        metadata = TorrentMetadata(
            infoHash: magnet.infoHash,
            name: torrent.title,
            totalSize: torrent.sizeBytes,
            pieceLength: pieceSize,
            pieces: piecesHash,
            files: [TorrentFile(path: [torrent.title], length: torrent.sizeBytes)],
            trackers: magnet.trackers.isEmpty ? ["http://tracker.openbittorrent.com:80/announce"] : magnet.trackers
        )

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

    private static func generatePeerId() -> String {
        let id = "-MB0001-" + (0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }
        return String(id)
    }
}

public enum StreamingOrchestratorError: Error, LocalizedError {
    case invalidMagnetURI
    case failedToInitialize

    public var errorDescription: String? {
        switch self {
        case .invalidMagnetURI: "Invalid magnet URI"
        case .failedToInitialize: "Failed to initialize streaming orchestrator"
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
        var peersFound: [PeerInfo] = []

        for tracker in metadata.trackers {
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
                    peersFound.append(contentsOf: response.peers)
                    NSLog("UDP tracker announce succeeded: \(tracker)")
                } catch {
                    NSLog("UDP tracker failed: \(tracker) - \(error)")
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
                    peersFound.append(contentsOf: response.peers)
                    NSLog("HTTP tracker announce succeeded: \(tracker)")
                } catch {
                    NSLog("HTTP tracker failed: \(tracker) - \(error)")
                }
            }
        }

        if peersFound.isEmpty {
            NSLog("No peers from trackers, falling back to DHT")
            await startDHT()
            let dhtPeers = await dht?.findPeers(infoHash: metadata.infoHash) ?? []
            peersFound.append(contentsOf: dhtPeers)
        }

        if !peersFound.isEmpty {
            await connectToPeers(peersFound)
        } else {
            NSLog("No peers found from any source")
        }

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
                    onPieceReceived: { [weak self] pieceIndex, block in
                        Task { @MainActor in
                            await self?.handlePieceReceived(pieceIndex: pieceIndex, block: block)
                        }
                    }
                )
            }
        }
    }

    private func handlePieceReceived(pieceIndex: UInt32, block: Data) async {
        let pieceComplete = await pieceManager.markBlockReceived(
            pieceIndex: pieceIndex,
            offset: 0,
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
