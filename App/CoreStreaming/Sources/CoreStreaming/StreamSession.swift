import Foundation
import CoreTorrent

@MainActor
public final class StreamSession: ObservableObject {
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

    private let orchestrator: StreamingOrchestrator
    private var monitorTask: Task<Void, Never>?
    private var streamURL: URL?
    private var isReady = false

    private static let bufferThresholdPieces = 2
    private static let bufferThresholdSeconds = 5.0

    public init(orchestrator: StreamingOrchestrator) {
        self.orchestrator = orchestrator
    }

    public func start(torrent: TorrentResult) async {
        state = .preparing
        do {
            streamURL = try await TaskTimeout.withTimeout(seconds: 50) { [self] in
                try await self.orchestrator.startStream(torrent: torrent) { [weak self] progress, speed, peers in
                    Task { @MainActor in
                        guard let self else { return }
                        self.downloadSpeed = speed
                        self.peerCount = peers
                        self.bufferedPieces = await self.orchestrator.contiguousPiecesFromStart()

                        let meetsThreshold = self.bufferedPieces >= Self.bufferThresholdPieces
                        if !self.isReady && meetsThreshold {
                            self.isReady = true
                            if let url = self.streamURL {
                                self.state = .ready(streamURL: url)
                            }
                        } else if !self.isReady {
                            self.state = .buffering(progress: progress)
                        }
                    }
                }
            }

            if let url = streamURL {
                let initialBuffered = await orchestrator.contiguousPiecesFromStart()
                if initialBuffered >= Self.bufferThresholdPieces {
                    isReady = true
                    state = .ready(streamURL: url)
                }
            }
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

    private func startBufferingWatchdog() {
        Task {
            try? await Task.sleep(for: .seconds(75))
            guard !Task.isCancelled, !isReady else { return }
            switch state {
            case .preparing, .buffering:
                await orchestrator.stop()
                let peers = await orchestrator.peerCount()
                state = .failed(
                    error: peers == 0
                        ? "No peers found — trackers may be unreachable or this release is dead. Try another version."
                        : "Buffering timed out (\(peers) peers connected). Try a release with more seeders."
                )
            default:
                break
            }
        }
    }

    public func cancel() async {
        state = .cancelled
        monitorTask?.cancel()
        monitorTask = nil
        await orchestrator.stop()
    }

    func failWithTimeout() async {
        await orchestrator.stop()
        state = .failed(error: "Streaming timed out. Try another release or check your connection.")
    }

    private func startMonitoring() {
        monitorTask = Task {
            while !Task.isCancelled {
                let progress = await orchestrator.progress()
                let speed = await orchestrator.downloadSpeed()
                let peers = await orchestrator.peerCount()
                let contiguous = await orchestrator.contiguousPiecesFromStart()

                await MainActor.run {
                    self.downloadSpeed = speed
                    self.peerCount = peers
                    self.bufferedPieces = contiguous
                }

                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
