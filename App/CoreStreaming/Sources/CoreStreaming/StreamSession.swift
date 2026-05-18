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
    @Published public private(set) var bufferedBytes: Int64 = 0

    private let orchestrator: StreamingOrchestrator
    private var monitorTask: Task<Void, Never>?
    private var streamURL: URL?

    /// Progressive play: one verified piece from the video start is enough (~256KB–4MB).
    /// The rest of the file continues downloading while AVPlayer reads ahead via HTTP ranges.
    private static let minimumBufferedPieces = 1
    /// Fallback when piece size is tiny — ~384KB covers most container headers.
    private static let minimumBufferedBytes: Int64 = 384 * 1024

    public init(orchestrator: StreamingOrchestrator) {
        self.orchestrator = orchestrator
    }

    public func start(torrent: TorrentResult) async {
        state = .preparing
        streamURL = nil
        bufferedPieces = 0
        bufferedBytes = 0

        do {
            streamURL = try await TaskTimeout.withTimeout(seconds: 50) { [self] in
                try await self.orchestrator.startStream(torrent: torrent) { [weak self] progress, speed, peers in
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
        bufferedBytes = await orchestrator.contiguousBytesFromStreamStart()
    }

    private func startBufferingWatchdog() {
        Task {
            try? await Task.sleep(for: .seconds(90))
            if case .ready = state { return }
            guard !Task.isCancelled else { return }
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

                await MainActor.run {
                    self.downloadSpeed = speed
                    self.peerCount = peers
                }
                await refreshBufferMetrics()
                await MainActor.run {
                    self.updatePlaybackReadiness(progress: progress)
                }

                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// Opens the player once the local HTTP URL is up and the head of the file is on disk.
    /// Does not wait for the full torrent — AVPlayer fetches ranges on demand.
    private func updatePlaybackReadiness(progress: Double) {
        guard let url = streamURL else {
            state = .preparing
            return
        }

        let hasHeadChunk = bufferedPieces >= Self.minimumBufferedPieces
            || bufferedBytes >= Self.minimumBufferedBytes

        if hasHeadChunk {
            if case .ready = state {} else {
                TorrentLog.info(
                    "[StreamSession] ▶️ Progressive play ready — \(bufferedPieces) piece(s), \(bufferedBytes) bytes buffered"
                )
                state = .ready(streamURL: url)
            }
        } else {
            let hint = max(progress, bufferedBytes > 0 ? 0.05 : 0.01)
            state = .buffering(progress: hint)
        }
    }
}
