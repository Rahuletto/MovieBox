import Foundation
import CoreTorrent
import CoreStorage

@MainActor
public final class DownloadManager: ObservableObject {
    public struct DownloadTask: Identifiable, Sendable {
        public let id: UUID
        public let tmdbId: Int
        public let title: String
        public let magnetURI: String
        public let quality: String
        public let hdrType: String?
        public var state: DownloadState
        public var progress: Double
        public var speed: Double
        public var peerCount: Int
        public var totalBytes: Int64
        public var downloadedBytes: Int64
        public var outputPath: String?

        public init(id: UUID = UUID(), tmdbId: Int, title: String, magnetURI: String, quality: String, hdrType: String? = nil) {
            self.id = id
            self.tmdbId = tmdbId
            self.title = title
            self.magnetURI = magnetURI
            self.quality = quality
            self.hdrType = hdrType
            self.state = .queued
            self.progress = 0
            self.speed = 0
            self.peerCount = 0
            self.totalBytes = 0
            self.downloadedBytes = 0
            self.outputPath = nil
        }
    }

    @Published public private(set) var tasks: [DownloadTask] = []
    @Published public private(set) var totalDownloadSpeed: Double = 0

    private var activeEngines: [UUID: TorrentEngine] = [:]
    private var pieceStores: [UUID: PieceStore] = [:]
    private var pieceManagers: [UUID: PieceManager] = [:]
    private let downloadDirectory: URL

    public init(downloadDirectory: URL? = nil) {
        if let dir = downloadDirectory {
            self.downloadDirectory = dir
        } else {
            self.downloadDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies")
                .appendingPathComponent("MovieBox")
        }
        try? FileManager.default.createDirectory(at: self.downloadDirectory, withIntermediateDirectories: true)
    }

    public func startDownload(tmdbId: Int, title: String, magnetURI: String, quality: String, hdrType: String? = nil) {
        let task = DownloadTask(tmdbId: tmdbId, title: title, magnetURI: magnetURI, quality: quality, hdrType: hdrType)
        tasks.append(task)
        Task {
            await executeDownload(task: task)
        }
    }

    public func pauseDownload(taskId: UUID) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[taskIndex].state = .paused
        if let engine = activeEngines[taskId] {
            engine.stop()
            activeEngines.removeValue(forKey: taskId)
        }
    }

    public func resumeDownload(taskId: UUID) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[taskIndex].state = .downloading
        let task = tasks[taskIndex]
        Task {
            await executeDownload(task: task)
        }
    }

    public func cancelDownload(taskId: UUID) {
        if let engine = activeEngines[taskId] {
            engine.stop()
            activeEngines.removeValue(forKey: taskId)
        }
        if let store = pieceStores[taskId] {
            Task { await store.cleanup() }
            pieceStores.removeValue(forKey: taskId)
        }
        pieceManagers.removeValue(forKey: taskId)
        tasks.removeAll(where: { $0.id == taskId })
    }

    public func removeCompleted(taskId: UUID) {
        tasks.removeAll(where: { $0.id == taskId && $0.state == .completed })
    }

    private func executeDownload(task: DownloadTask) async {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == task.id }) else { return }

        tasks[taskIndex].state = .downloading

        let peerId = "-MB0001-" + (0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }
        let magnet = MagnetURI(from: task.magnetURI)
        guard let magnet else {
            tasks[taskIndex].state = .failed
            return
        }

        let metadata: TorrentMetadata
        do {
            metadata = try await TorrentMetadataFetcher.fetch(
                infoHash: magnet.infoHash,
                magnetTrackers: magnet.trackers
            )
        } catch {
            tasks[taskIndex].state = .failed
            return
        }

        let outputDir = downloadDirectory.appendingPathComponent(task.title)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        do {
            let store = try await PieceStore(
                infoHash: metadata.infoHash,
                pieceCount: metadata.pieceCount,
                pieceSize: metadata.pieceLength,
                storageDirectory: outputDir
            )
            pieceStores[task.id] = store

            let manager = PieceManager(
                pieceCount: metadata.pieceCount,
                pieceLength: metadata.pieceLength,
                totalSize: metadata.totalSize,
                piecesHash: metadata.pieces
            )
            pieceManagers[task.id] = manager

            let engine = TorrentEngine(
                metadata: metadata,
                pieceManager: manager,
                pieceStore: store,
                peerId: peerId
            ) { [weak self] progress, speed, peers in
                Task { @MainActor in
                    guard let self, let idx = self.tasks.firstIndex(where: { $0.id == task.id }) else { return }
                    self.tasks[idx].progress = progress
                    self.tasks[idx].speed = speed
                    self.tasks[idx].peerCount = peers
                    self.tasks[idx].downloadedBytes = Int64(progress * Double(metadata.totalSize))
                    self.tasks[idx].totalBytes = metadata.totalSize
                    if progress >= 1.0 {
                        self.tasks[idx].state = .completed
                        self.tasks[idx].outputPath = outputDir.path
                    }
                }
            }

            activeEngines[task.id] = engine
            await engine.start()

        } catch {
            if let taskIndex = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[taskIndex].state = .failed
            }
        }
    }
}
