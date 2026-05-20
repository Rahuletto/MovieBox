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
        let verifiedBytes = await orchestrator.contiguousBytesFromStreamStart()
        let headBytes = await orchestrator.streamHeadContiguousBytes()
        bufferedBytes = max(verifiedBytes, headBytes)
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
            guard let self else { return }
            let timeout = await self.bufferingWatchdogSeconds()
            try? await Task.sleep(for: .seconds(timeout))
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
            guard let self else { return }
            while !Task.isCancelled {
                let progress = await orchestrator.progress()
                let speed = await orchestrator.downloadSpeed()
                let peers = await orchestrator.peerCount()
                let transferring = await orchestrator.transferringPeerCount()

                downloadSpeed = speed
                peerCount = peers
                transferringPeerCount = transferring
                await refreshBufferMetrics()
                await updatePlaybackReadiness(progress: progress)

                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func updatePlaybackReadiness(progress: Double) async {
        guard let url = streamURL else {
            state = .preparing
            return
        }

        let hasVerifiedHead = bufferedPieces >= 1
        let verifiedHeadBytes = await orchestrator.contiguousBytesFromStreamStart()
        let hasEnoughVerifiedHead = verifiedHeadBytes >= StreamPlaybackThreshold.minimumHeadBytes
        let needsTail = await orchestrator.streamTargetNeedsTailProbe()
        let hasTail = needsTail ? await orchestrator.isStreamTailPieceReady() : true

        if hasVerifiedHead, hasEnoughVerifiedHead, hasTail {
            if case .ready = state {} else {
                let (tailVerified, tailTotal) = await tailBufferProgress()
                TorrentLog.info(
                    "[StreamSession] buffer ready — \(verifiedHeadBytes / 1024) KB verified head (need \(StreamPlaybackThreshold.minimumHeadBytes / 1024) KB), tail=\(tailVerified)/\(tailTotal) pieces, \(bufferedPieces) contiguous head piece(s), \(peerCount) live peers (\(transferringPeerCount) transferring)"
                )
                state = .ready(streamURL: url)
            }
        } else {
            let headProgress = min(1, Double(verifiedHeadBytes) / Double(StreamPlaybackThreshold.minimumHeadBytes))
            let (tailVerified, tailTotal) = await tailBufferProgress()
            let tailProgress = needsTail ? min(1, Double(tailVerified) / Double(tailTotal)) : 1
            let hint = max(progress, headProgress * 0.45 + tailProgress * 0.45, 0.02)
            if case .preparing = state {
                TorrentLog.info(
                    "[StreamSession] buffering — \(verifiedHeadBytes / 1024)/\(StreamPlaybackThreshold.minimumHeadBytes / 1024) KB verified head, \(peerCount) live peers (\(transferringPeerCount) transferring, indexer: \(swarmSeeders) seeders), \(Int(downloadSpeed / 1024)) KB/s"
                )
            }
            state = .buffering(progress: hint)
        }
    }

    /// Verified bytes from the stream file start (hash-checked). Safe to call from app modules.
    public func verifiedHeadBytes() async -> Int64 {
        await orchestrator.contiguousBytesFromStreamStart()
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
