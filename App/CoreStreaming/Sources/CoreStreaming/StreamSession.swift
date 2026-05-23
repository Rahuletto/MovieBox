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
    /// Cached row/pill metrics — updated by the session monitor (avoid duplicate heavy polling).
    @Published public private(set) var rowMetrics: StreamRowBufferingMetrics?

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
        rowMetrics = nil
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
        180
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
                let indexLabel = await orchestrator.streamIndexProbeLabel()
                let minKB = (indexLabel.contains("MKV")
                    ? StreamPlaybackThreshold.minimumContiguousHeadBytesForMKV
                    : StreamPlaybackThreshold.minimumContiguousHeadBytesForMP4) / 1024
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
        rowMetrics = nil
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
                    await strongSelf.refreshRowMetrics()
                    switch strongSelf.state {
                    case .failed, .cancelled:
                        break
                    default:
                        shouldContinue = true
                    }
                }

                guard shouldContinue else { break }

                do {
                    try? await Task.yield()
                    try await Task.sleep(for: .milliseconds(900))
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

        // Terminal states: stop tail/index probing (avoids log spam after ready or failure).
        switch state {
        case .ready, .failed, .cancelled:
            return
        default:
            break
        }

        let indexLabel = await orchestrator.streamIndexProbeLabel()
        let isMKV = indexLabel.contains("MKV")
        let headThreshold = isMKV
            ? StreamPlaybackThreshold.minimumContiguousHeadBytesForMKV
            : StreamPlaybackThreshold.minimumContiguousHeadBytesForMP4

        let verifiedHeadBytes = await orchestrator.verifiedMediaBytesFromStart()
        let inFlightHeadBytes = await orchestrator.streamHeadContiguousBytes()
        // FINDINGS Tier 1 #3: no moov-on-disk gate — piece 0 verified (MP4) or MKV head threshold.
        let hasEnoughHead = await orchestrator.hasMinimumPlaybackHead()

        if hasEnoughHead {
            // Live peer gate: a resumed session with cached pieces but 0 peers will
            // fail the moment AVPlayer requests a byte we don't have. Only bypass
            // the gate if literally every piece in this file is already on disk.
            let hasLivePeers = peerCount > 0 || transferringPeerCount > 0
            let fullyCached = await orchestrator.allStreamPiecesVerified()
            guard hasLivePeers || fullyCached else {
                let tailFraction = await orchestrator.streamTailPiecesProgress()
                let headProgress = min(1.0, Double(verifiedHeadBytes) / Double(headThreshold))
                let tailProgress = min(1.0, tailFraction)
            let headWeight = isMKV ? 0.55 : 0.90
            let overallProgress = (headProgress * headWeight) + (tailProgress * (1 - headWeight))
            let hint = max(progress, overallProgress, 0.15)
                if case .preparing = state {
                    TorrentLog.info(
                        "[StreamSession] buffering — head ready but no live peers yet (\(peerCount) live, \(transferringPeerCount) transferring) — holding ready"
                    )
                }
                state = .buffering(progress: hint)
                return
            }

            let (tailVerified, tailTotal) = await tailBufferProgress()
            TorrentLog.info(
                "[StreamSession] buffer ready — \(verifiedHeadBytes / 1024) KB verified head (\(inFlightHeadBytes / 1024) KB in-flight, need \(headThreshold / 1024) KB), tail=\(tailVerified)/\(tailTotal) pieces, \(bufferedPieces) contiguous head piece(s), \(peerCount) live peers (\(transferringPeerCount) transferring), fullyCached=\(fullyCached)"
            )
            state = .ready(streamURL: url)
        } else {
            // Drive progress from head accumulation (0→90%) + tail progress (0→10%).
            // AVPlayer fetches moov/index tail via range requests once pieces are downloaded.
            let tailFraction = await orchestrator.streamTailPiecesProgress()
            let headProgress = min(1.0, Double(verifiedHeadBytes) / Double(headThreshold))
            let tailProgress = min(1.0, tailFraction)
            let headWeight = isMKV ? 0.55 : 0.90
            let overallProgress = (headProgress * headWeight) + (tailProgress * (1 - headWeight))
            let hint = max(progress, overallProgress, 0.02)
            if case .preparing = state {
                TorrentLog.info(
                    "[StreamSession] buffering — \(verifiedHeadBytes / 1024)/\(headThreshold / 1024) KB verified head (\(inFlightHeadBytes / 1024) KB in-flight), \(peerCount) live peers (\(transferringPeerCount) transferring, indexer: \(swarmSeeders) seeders), \(Int(downloadSpeed / 1024)) KB/s"
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

    private func refreshRowMetrics() async {
        rowMetrics = await buildRowBufferingMetrics()
    }

    public func rowBufferingMetrics() async -> StreamRowBufferingMetrics {
        if let rowMetrics { return rowMetrics }
        return await buildRowBufferingMetrics()
    }

    private func buildRowBufferingMetrics() async -> StreamRowBufferingMetrics {
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
