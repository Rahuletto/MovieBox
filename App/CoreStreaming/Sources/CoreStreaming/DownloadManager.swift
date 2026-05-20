import Foundation
import CoreStorage
import CoreTorrent

@MainActor
public final class DownloadManager: ObservableObject {
    public struct DownloadTask: Identifiable, Sendable {
        public let id: UUID
        public let tmdbId: Int
        public let mediaKind: String
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
        public var infoHash: String?
        public var storageDirectory: URL?

        public init(
            id: UUID = UUID(),
            tmdbId: Int,
            mediaKind: String = "movie",
            title: String,
            magnetURI: String,
            quality: String,
            hdrType: String? = nil
        ) {
            self.id = id
            self.tmdbId = tmdbId
            self.mediaKind = mediaKind
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
            self.infoHash = nil
            self.storageDirectory = nil
        }
    }

    @Published public private(set) var tasks: [DownloadTask] = []
    @Published public private(set) var totalDownloadSpeed: Double = 0

    public weak var persistenceDelegate: DownloadPersistenceDelegate?

    private var activeEngines: [UUID: TorrentEngine] = [:]
    private var pieceStores: [UUID: PieceStore] = [:]
    private var pieceManagers: [UUID: PieceManager] = [:]
    private var metadataByTask: [UUID: TorrentMetadata] = [:]
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

    public func restoreTask(
        id: UUID,
        tmdbId: Int,
        mediaKind: String,
        title: String,
        magnetURI: String,
        quality: String,
        hdrType: String?,
        infoHash: String,
        state: DownloadState,
        progress: Double,
        totalBytes: Int64,
        downloadedBytes: Int64,
        localFilePath: String?,
        storageDirectory: URL,
        pieceBitmap: Data? = nil
    ) {
        var task = DownloadTask(
            id: id,
            tmdbId: tmdbId,
            mediaKind: mediaKind,
            title: title,
            magnetURI: magnetURI,
            quality: quality,
            hdrType: hdrType
        )
        task.state = state
        task.progress = progress
        task.totalBytes = totalBytes
        task.downloadedBytes = downloadedBytes
        task.outputPath = localFilePath
        task.infoHash = infoHash
        task.storageDirectory = storageDirectory
        if !tasks.contains(where: { $0.id == id }) {
            tasks.append(task)
        }
        if state == .downloading || state == .queued {
            Task { await executeDownload(taskId: id, resume: true, existingBitmap: pieceBitmap) }
        }
    }

    @discardableResult
    public func startDownload(
        tmdbId: Int,
        mediaKind: String = "movie",
        title: String,
        magnetURI: String,
        quality: String,
        hdrType: String? = nil
    ) -> UUID {
        let task = DownloadTask(
            tmdbId: tmdbId,
            mediaKind: mediaKind,
            title: title,
            magnetURI: magnetURI,
            quality: quality,
            hdrType: hdrType
        )
        tasks.append(task)
        persist(task)
        Task { await executeDownload(taskId: task.id, resume: false, existingBitmap: nil) }
        return task.id
    }

    public func pauseDownload(taskId: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[index].state = .paused
        if let engine = activeEngines[taskId] {
            engine.stop()
            activeEngines.removeValue(forKey: taskId)
        }
        persist(tasks[index])
    }

    public func resumeDownload(taskId: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[index].state = .downloading
        persist(tasks[index])
        Task { await executeDownload(taskId: taskId, resume: true, existingBitmap: nil) }
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
        metadataByTask.removeValue(forKey: taskId)
        if let hash = tasks.first(where: { $0.id == taskId })?.infoHash {
            persistenceDelegate?.downloadManager(self, didRemove: hash)
        }
        tasks.removeAll(where: { $0.id == taskId })
    }

    public func removeCompleted(taskId: UUID) {
        if let task = tasks.first(where: { $0.id == taskId }), task.state == .completed {
            if let hash = task.infoHash {
                persistenceDelegate?.downloadManager(self, didRemove: hash)
            }
            tasks.removeAll(where: { $0.id == taskId })
        }
    }

    private func executeDownload(taskId: UUID, resume: Bool, existingBitmap: Data?) async {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        var task = tasks[index]
        guard task.state == .downloading || task.state == .queued else { return }

        tasks[index].state = .downloading
        task.state = .downloading

        let peerId = BitTorrentPeerID.make()
        let magnet = MagnetURI(from: task.magnetURI)
        guard let infoHash = magnet?.infoHash else {
            tasks[index].state = .failed
            persist(tasks[index])
            return
        }

        tasks[index].infoHash = infoHash
        task.infoHash = infoHash

        let metadata: TorrentMetadata
        do {
            metadata = try await TorrentMetadataFetcher.fetch(
                infoHash: infoHash,
                magnetTrackers: magnet?.trackers ?? []
            )
        } catch {
            tasks[index].state = .failed
            persist(tasks[index])
            return
        }

        do {
            try TorrentLimits.validateTotalSize(metadata.totalSize)
        } catch {
            tasks[index].state = .failed
            persist(tasks[index])
            return
        }

        metadataByTask[taskId] = metadata

        let safeTitle = task.title.replacingOccurrences(of: "/", with: "_")
        let outputDir = downloadDirectory.appendingPathComponent(safeTitle, isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        tasks[index].storageDirectory = outputDir
        tasks[index].totalBytes = metadata.totalSize

        let storeBitmap: Data?
        if let existingBitmap, !existingBitmap.isEmpty {
            storeBitmap = existingBitmap
        } else if resume, let store = pieceStores[taskId] {
            storeBitmap = await store.encodedBitmap()
        } else {
            storeBitmap = nil
        }

        do {
            let store: PieceStore
            if resume, pieceStores[taskId] != nil, let existing = pieceStores[taskId] {
                store = existing
            } else {
                store = try await PieceStore(
                    infoHash: metadata.infoHash,
                    pieceCount: metadata.pieceCount,
                    pieceSize: metadata.pieceLength,
                    totalSize: metadata.totalSize,
                    storageDirectory: outputDir,
                    existingBitmap: storeBitmap,
                    recreateFile: !resume
                )
                pieceStores[taskId] = store
            }

            let manager: PieceManager
            if let existing = pieceManagers[taskId] {
                manager = existing
            } else {
                manager = PieceManager(
                    pieceCount: metadata.pieceCount,
                    pieceLength: metadata.pieceLength,
                    totalSize: metadata.totalSize,
                    piecesHash: metadata.pieces
                )
                pieceManagers[taskId] = manager
            }

            let engine = TorrentEngine(
                metadata: metadata,
                pieceManager: manager,
                pieceStore: store,
                peerId: peerId
            ) { [weak self] progress, speed, peers in
                Task { @MainActor in
                    await self?.handleProgress(
                        taskId: taskId,
                        metadata: metadata,
                        outputDir: outputDir,
                        progress: progress,
                        speed: speed,
                        peers: peers
                    )
                }
            }

            activeEngines[taskId] = engine
            await engine.start()
            persist(tasks[index])
        } catch {
            if let idx = tasks.firstIndex(where: { $0.id == taskId }) {
                tasks[idx].state = .failed
                persist(tasks[idx])
            }
        }
    }

    private func handleProgress(
        taskId: UUID,
        metadata: TorrentMetadata,
        outputDir: URL,
        progress: Double,
        speed: Double,
        peers: Int
    ) async {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[index].progress = progress
        tasks[index].speed = speed
        tasks[index].peerCount = peers
        tasks[index].downloadedBytes = Int64(progress * Double(metadata.totalSize))
        tasks[index].totalBytes = metadata.totalSize

        if progress >= 1.0, tasks[index].state != .completed {
            tasks[index].state = .completed
            if let store = pieceStores[taskId] {
                do {
                    let storePath = store.storageURL
                    let fileURL = try TorrentFileAssembler.exportPrimaryFile(
                        metadata: metadata,
                        pieceStorePath: storePath,
                        outputDirectory: outputDir
                    )
                    tasks[index].outputPath = fileURL.path
                    await store.cleanup()
                    pieceStores.removeValue(forKey: taskId)
                } catch {
                    tasks[index].state = .failed
                    TorrentLog.warn("[DownloadManager] Assembly failed: \(error.localizedDescription)")
                }
            }
            activeEngines[taskId]?.stop()
            activeEngines.removeValue(forKey: taskId)
            pieceManagers.removeValue(forKey: taskId)
            metadataByTask.removeValue(forKey: taskId)
        }

        persist(tasks[index])
    }

    private func persist(_ task: DownloadTask) {
        guard let infoHash = task.infoHash else { return }
        let dir = task.storageDirectory?.path ?? downloadDirectory.path
        let bitmap: Data
        if let store = pieceStores[task.id] {
            Task {
                let encoded = await store.encodedBitmap()
                await MainActor.run {
                    self.persistenceDelegate?.downloadManager(
                        self,
                        didUpdate: DownloadPersistenceSnapshot(
                            taskId: task.id,
                            infoHash: infoHash,
                            tmdbId: task.tmdbId,
                            mediaKind: task.mediaKind,
                            title: task.title,
                            magnetURI: task.magnetURI,
                            quality: task.quality,
                            hdrType: task.hdrType,
                            state: task.state.rawValue,
                            progress: task.progress,
                            totalBytes: task.totalBytes,
                            downloadedBytes: task.downloadedBytes,
                            localFilePath: task.outputPath,
                            pieceBitmap: encoded,
                            storageDirectory: dir
                        )
                    )
                }
            }
        } else {
            bitmap = Data()
            persistenceDelegate?.downloadManager(
                self,
                didUpdate: DownloadPersistenceSnapshot(
                    taskId: task.id,
                    infoHash: infoHash,
                    tmdbId: task.tmdbId,
                    mediaKind: task.mediaKind,
                    title: task.title,
                    magnetURI: task.magnetURI,
                    quality: task.quality,
                    hdrType: task.hdrType,
                    state: task.state.rawValue,
                    progress: task.progress,
                    totalBytes: task.totalBytes,
                    downloadedBytes: task.downloadedBytes,
                    localFilePath: task.outputPath,
                    pieceBitmap: bitmap,
                    storageDirectory: dir
                )
            )
        }
    }
}
