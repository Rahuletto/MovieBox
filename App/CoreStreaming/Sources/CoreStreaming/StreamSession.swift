import Foundation
import CoreTorrent

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
    @Published public private(set) var bufferedPieces: Int = 0
    @Published public private(set) var bufferedBytes: Int64 = 0

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

        do {
            let orchestrator = orchestrator
            streamURL = try await TaskTimeout.withTimeout(seconds: 50) {
                try await orchestrator.startStream(torrent: torrent) { [weak self] progress, speed, peers in
                    Task { @MainActor in
                        guard let self else { return }
                        self.downloadSpeed = speed
                        self.peerCount = peers
                        await self.refreshBufferMetrics()
                        self.updatePlaybackReadiness(progress: progress)
                    }
                }
            }

            await refreshBufferMetrics()
            updatePlaybackReadiness(progress: await orchestrator.progress())
            startMonitoring()
            startBufferingWatchdog()
        } catch is TaskTimeoutError {
            await orchestrator.stop()
            state = .failed(error: "Could not load torrent metadata in time. Try another release.")
        } catch {
            await orchestrator.stop()
            state = .failed(error: error.localizedDescription)
        }
    }

    private func refreshBufferMetrics() async {
        bufferedPieces = await orchestrator.contiguousPiecesFromStart()
        let verifiedBytes = await orchestrator.contiguousBytesFromStreamStart()
        let headBytes = await orchestrator.streamHeadContiguousBytes()
        bufferedBytes = max(verifiedBytes, headBytes)
    }

    private func startBufferingWatchdog() {
        bufferingWatchdogTask?.cancel()
        bufferingWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(150))
            guard !Task.isCancelled else { return }
            if case .ready = state { return }
            switch state {
            case .preparing, .buffering:
                // Snapshot before stop — peerCount drops to 0 after engine teardown (was misreported as "no peers").
                let peersSnapshot = await orchestrator.peerCount()
                let headKB = await orchestrator.streamHeadContiguousBytes() / 1024
                await orchestrator.stop()
                let minKB = StreamPlaybackThreshold.minimumHeadBytes / 1024
                let message: String
                if headKB > 0 {
                    message =
                        "Buffering stalled at \(headKB) KB (need ~\(minKB) KB at file start). Had \(peersSnapshot) peer(s). Try another release or wait for more seeders."
                } else if peersSnapshot == 0 {
                    message =
                        "No peers returned data — trackers may be unreachable or this swarm is dead. Try another version."
                } else {
                    message =
                        "Buffering timed out (\(peersSnapshot) peer(s), 0 KB at file start). Try another release."
                }
                state = .failed(error: message)
                monitorTask?.cancel()
                monitorTask = nil
            default:
                break
            }
        }
    }

    public func cancel() async {
        bufferingWatchdogTask?.cancel()
        bufferingWatchdogTask = nil
        state = .cancelled
        monitorTask?.cancel()
        monitorTask = nil
        await orchestrator.stop()
    }

    public func failWithTimeout() async {
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

                downloadSpeed = speed
                peerCount = peers
                await refreshBufferMetrics()
                updatePlaybackReadiness(progress: progress)

                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func updatePlaybackReadiness(progress: Double) {
        guard let url = streamURL else {
            state = .preparing
            return
        }

        let hasVerifiedHead = bufferedPieces >= 1
        let hasContiguousHead = bufferedBytes >= StreamPlaybackThreshold.minimumHeadBytes

        if hasVerifiedHead || hasContiguousHead {
            if case .ready = state {} else {
                TorrentLog.debug(
                    "[StreamSession] Buffer ready — \(bufferedBytes / 1024) KB head, \(bufferedPieces) verified piece(s)"
                )
                state = .ready(streamURL: url)
            }
        } else {
            let fraction = min(1, Double(bufferedBytes) / Double(StreamPlaybackThreshold.minimumHeadBytes))
            let hint = max(progress, fraction * 0.9, 0.02)
            state = .buffering(progress: hint)
        }
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
}
