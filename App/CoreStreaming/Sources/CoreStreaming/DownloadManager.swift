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
        public var failureMessage: String?

        public init(
            id: UUID = UUID(),
            tmdbId: Int,
            mediaKind: String = "movie",
            title: String,
            magnetURI: String,
            quality: String,
            hdrType: String? = nil,
            infoHash: String? = nil
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
            self.infoHash = infoHash.flatMap { MagnetURI.normalizeInfoHash($0) }
            self.storageDirectory = nil
            self.failureMessage = nil
        }
    }

    @Published public private(set) var tasks: [DownloadTask] = []
    @Published public private(set) var totalDownloadSpeed: Double = 0

    public weak var persistenceDelegate: DownloadPersistenceDelegate?

    private var activeEngines: [UUID: TorrentEngine] = [:]
    private var pieceStores: [UUID: PieceStore] = [:]
    private var pieceManagers: [UUID: PieceManager] = [:]
    private var metadataByTask: [UUID: TorrentMetadata] = [:]
    private var executionTasks: [UUID: Task<Void, Never>] = [:]
    private var downloadDirectory: URL

    private func isRunnableState(_ state: DownloadState) -> Bool {
        state == .downloading || state == .queued
    }

    private func shouldContinueExecution(for taskId: UUID) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let task = tasks.first(where: { $0.id == taskId }) else { return false }
        return isRunnableState(task.state)
    }

    private func cancelExecution(for taskId: UUID) {
        executionTasks[taskId]?.cancel()
        executionTasks.removeValue(forKey: taskId)
    }

    private func scheduleExecuteDownload(
        taskId: UUID,
        resume: Bool,
        existingBitmap: Data?
    ) {
        cancelExecution(for: taskId)
        executionTasks[taskId] = Task { [weak self] in
            await self?.executeDownload(taskId: taskId, resume: resume, existingBitmap: existingBitmap)
            await MainActor.run { [weak self] in
                self?.executionTasks.removeValue(forKey: taskId)
            }
        }
    }

    public var downloadRootDirectory: URL { downloadDirectory }

    public init(downloadDirectory: URL? = nil) {
        if let dir = downloadDirectory {
            self.downloadDirectory = dir.standardizedFileURL
        } else {
            self.downloadDirectory = DownloadStorage.defaultRootDirectory()
        }
        try? DownloadStorage.prepareDirectory(at: self.downloadDirectory)
    }

    /// Updates the root folder for new downloads (existing tasks keep their `storageDirectory`).
    public func configureDownloadRoot(_ url: URL) throws {
        let resolved = url.standardizedFileURL
        try DownloadStorage.prepareDirectory(at: resolved)
        downloadDirectory = resolved
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
            scheduleExecuteDownload(taskId: id, resume: true, existingBitmap: pieceBitmap)
        }
    }

    @discardableResult
    public func startDownload(
        tmdbId: Int,
        mediaKind: String = "movie",
        title: String,
        magnetURI: String,
        quality: String,
        hdrType: String? = nil,
        infoHash: String? = nil
    ) -> UUID {
        let resolvedHash = infoHash.flatMap { MagnetURI.normalizeInfoHash($0) }
            ?? DownloadIdentity.resolve(magnetURI: magnetURI, storedInfoHash: infoHash)?.infoHash

        if let resolvedHash,
           let existingIndex = tasks.firstIndex(where: {
               $0.infoHash == resolvedHash && $0.state != .completed && $0.state != .failed
           }) {
            let existing = tasks[existingIndex]
            switch existing.state {
            case .paused:
                resumeDownload(taskId: existing.id)
            case .queued, .downloading:
                break
            default:
                break
            }
            return existing.id
        }

        let task = DownloadTask(
            tmdbId: tmdbId,
            mediaKind: mediaKind,
            title: title,
            magnetURI: magnetURI,
            quality: quality,
            hdrType: hdrType,
            infoHash: resolvedHash
        )
        tasks.append(task)
        persist(task)
        scheduleExecuteDownload(taskId: task.id, resume: false, existingBitmap: nil)
        return task.id
    }

    public func retryDownload(taskId: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        guard tasks[index].state == .failed else { return }

        if let engine = activeEngines[taskId] {
            engine.stop()
            activeEngines.removeValue(forKey: taskId)
        }

        tasks[index].state = .queued
        tasks[index].failureMessage = nil
        let task = tasks[index]
        persist(task)
        scheduleExecuteDownload(
            taskId: taskId,
            resume: true,
            existingBitmap: restoredBitmap(for: task)
        )
    }

    public func pauseDownload(taskId: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        cancelExecution(for: taskId)
        tasks[index].state = .paused
        if let engine = activeEngines[taskId] {
            engine.stop()
            activeEngines.removeValue(forKey: taskId)
        }
        persist(tasks[index])
    }

    public func resumeDownload(taskId: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        mutateTask(at: index) { $0.state = .downloading }
        let task = tasks[index]
        persist(task)
        let bitmap = restoredBitmap(for: task)
        scheduleExecuteDownload(taskId: taskId, resume: true, existingBitmap: bitmap)
    }

    /// Writes piece bitmaps and SwiftData snapshots before the process exits.
    public func flushPersistenceForTermination() async {
        for task in tasks where task.state == .downloading || task.state == .queued || task.state == .paused {
            if let store = pieceStores[task.id], let hash = task.infoHash, let dir = task.storageDirectory {
                let encoded = await store.encodedBitmap()
                DownloadBitmapPersistence.save(encoded, infoHash: hash, in: dir)
                persistSnapshot(task: task, pieceBitmap: encoded)
            } else {
                persist(task)
            }
        }
    }

    private func restoredBitmap(for task: DownloadTask) -> Data? {
        if let hash = task.infoHash, let dir = task.storageDirectory,
           let sidecar = DownloadBitmapPersistence.loadBitmap(infoHash: hash, in: dir) {
            return sidecar
        }
        return nil
    }

    private func persistSnapshot(task: DownloadTask, pieceBitmap: Data) {
        guard let infoHash = task.infoHash else { return }
        let dir = task.storageDirectory?.path ?? downloadDirectory.path
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
                pieceBitmap: pieceBitmap,
                storageDirectory: dir
            )
        )
    }

    public func cancelDownload(taskId: UUID) {
        cancelExecution(for: taskId)
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
        guard !Task.isCancelled else { return }
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        var task = tasks[index]
        guard isRunnableState(task.state) else { return }

        mutateTask(at: index) { task in
            task.state = .downloading
            task.failureMessage = nil
        }
        task.state = .downloading
        task.failureMessage = nil

        let peerId = BitTorrentPeerID.make()
        guard let identity = DownloadIdentity.resolve(
            magnetURI: task.magnetURI,
            storedInfoHash: task.infoHash
        ) else {
            markFailed(
                taskId: taskId,
                message: "This release has an invalid magnet link or info hash.",
                log: "[DownloadManager] invalid identity — title=\"\(task.title)\""
            )
            return
        }

        let infoHash = identity.infoHash
        mutateTask(at: index) { $0.infoHash = infoHash }
        task.infoHash = infoHash

        TorrentLog.info(
            "[DownloadManager] fetching metadata — hash=\(infoHash.prefix(8))… trackers=\(identity.magnetTrackers.count) title=\"\(task.title)\""
        )

        let metadata: TorrentMetadata
        do {
            metadata = try await Task.detached(priority: .userInitiated) {
                try await TorrentMetadataFetcher.fetch(
                    infoHash: infoHash,
                    magnetTrackers: identity.magnetTrackers
                )
            }.value
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            markFailed(
                taskId: taskId,
                message: message.isEmpty
                    ? "Could not load torrent metadata for this release."
                    : message,
                log: "[DownloadManager] metadata failed — \(message)"
            )
            return
        }

        do {
            try TorrentLimits.validateTotalSize(metadata.totalSize)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            markFailed(
                taskId: taskId,
                message: message,
                log: "[DownloadManager] size rejected — \(message)"
            )
            return
        }

        guard shouldContinueExecution(for: taskId) else { return }

        metadataByTask[taskId] = metadata

        let safeTitle = task.title.replacingOccurrences(of: "/", with: "_")
        let outputDir = downloadDirectory.appendingPathComponent(safeTitle, isDirectory: true)
        do {
            try DownloadStorage.prepareDirectory(at: outputDir)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            markFailed(
                taskId: taskId,
                message: message,
                log: "[DownloadManager] output directory not writable — \(outputDir.path) — \(message)"
            )
            return
        }
        mutateTask(at: index) { task in
            task.storageDirectory = outputDir
            task.totalBytes = metadata.totalSize
        }

        let storeBitmap: Data?
        if let existingBitmap, !existingBitmap.isEmpty {
            storeBitmap = existingBitmap
        } else if resume, let hash = task.infoHash, let dir = task.storageDirectory,
                  let sidecar = DownloadBitmapPersistence.loadBitmap(infoHash: hash, in: dir) {
            storeBitmap = sidecar
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

            guard shouldContinueExecution(for: taskId) else { return }

            activeEngines[taskId] = engine
            await engine.start()

            guard shouldContinueExecution(for: taskId) else {
                engine.stop()
                activeEngines.removeValue(forKey: taskId)
                return
            }
            persist(tasks[index])
        } catch {
            let message = error.localizedDescription
            markFailed(
                taskId: taskId,
                message: message.isEmpty
                    ? "Could not start the download engine."
                    : message,
                log: "[DownloadManager] engine setup failed — \(message)"
            )
        }
    }

    private func markFailed(taskId: UUID, message: String, log: String) {
        TorrentLog.warn(log)
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        mutateTask(at: index) { task in
            task.state = .failed
            task.failureMessage = message
        }
        persist(tasks[index])
    }

    /// Reassigns the task so `@Published` emits (in-place struct mutation does not).
    private func mutateTask(at index: Int, _ body: (inout DownloadTask) -> Void) {
        var task = tasks[index]
        body(&task)
        tasks[index] = task
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
        guard tasks[index].state == .downloading else { return }

        var didComplete = false
        mutateTask(at: index) { task in
            task.progress = progress
            task.speed = speed
            task.peerCount = peers
            task.downloadedBytes = Int64(progress * Double(metadata.totalSize))
            task.totalBytes = metadata.totalSize

            if progress >= 1.0, task.state != .completed {
                task.state = .completed
                didComplete = true
            }
        }

        if didComplete {
            if let store = pieceStores[taskId] {
                do {
                    let storePath = store.storageURL
                    let fileURL = try TorrentFileAssembler.exportPrimaryFile(
                        metadata: metadata,
                        pieceStorePath: storePath,
                        outputDirectory: outputDir
                    )
                    mutateTask(at: index) { $0.outputPath = fileURL.path }
                    if let hash = tasks[index].infoHash {
                        DownloadBitmapPersistence.remove(
                            infoHash: hash,
                            in: outputDir
                        )
                    }
                    await store.cleanup()
                    pieceStores.removeValue(forKey: taskId)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    mutateTask(at: index) { task in
                        task.state = .failed
                        task.failureMessage = message.isEmpty
                            ? "Download finished but the file could not be assembled."
                            : message
                    }
                    TorrentLog.warn("[DownloadManager] assembly failed — \(message)")
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
            let taskId = task.id
            Task { [weak self] in
                let encoded = await store.encodedBitmap()
                await MainActor.run { [weak self] in
                    guard let self, self.tasks.contains(where: { $0.id == taskId }) else { return }
                    if let storageDir = task.storageDirectory {
                        DownloadBitmapPersistence.save(encoded, infoHash: infoHash, in: storageDir)
                    }
                    self.persistSnapshot(task: task, pieceBitmap: encoded)
                }
            }
        } else {
            persistSnapshot(task: task, pieceBitmap: Data())
        }
    }
}
