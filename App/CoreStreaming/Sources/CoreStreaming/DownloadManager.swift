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
    @Published public private(set) var reexportingTaskIds: Set<UUID> = []

    public weak var persistenceDelegate: DownloadPersistenceDelegate?
    /// Called on the main actor whenever the task list or progress changes (Dock tile, etc.).
    public var onTasksUpdated: (@MainActor () -> Void)?

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
        let normalizedHash = MagnetURI.normalizeInfoHash(infoHash) ?? infoHash.lowercased()
        task.infoHash = normalizedHash
        task.storageDirectory = storageDirectory

        if let existingIndex = tasks.firstIndex(where: {
            ($0.infoHash ?? "").lowercased() == normalizedHash
        }) {
            let existingId = tasks[existingIndex].id
            mutateTask(taskId: existingId) { existing in
                existing.state = state
                existing.progress = max(existing.progress, progress)
                existing.totalBytes = max(existing.totalBytes, totalBytes)
                existing.downloadedBytes = max(existing.downloadedBytes, downloadedBytes)
                existing.outputPath = localFilePath ?? existing.outputPath
                existing.storageDirectory = storageDirectory
            }
            if state == .downloading || state == .queued {
                scheduleExecuteDownload(taskId: existingId, resume: true, existingBitmap: pieceBitmap)
            }
            return
        }

        if !tasks.contains(where: { $0.id == id }) {
            tasks.append(task)
            notifyTasksUpdated()
        }
        if state == .downloading || state == .queued {
            scheduleExecuteDownload(taskId: id, resume: true, existingBitmap: pieceBitmap)
        }
    }

    /// Collapses duplicate rows for the same torrent hash (keeps the one with the most data).
    public func deduplicateTasks() {
        var bestIndexByHash: [String: Int] = [:]
        var indicesToRemove: Set<Int> = []

        for (index, task) in tasks.enumerated() {
            guard let hash = task.infoHash?.lowercased(), !hash.isEmpty else { continue }
            if let existingIndex = bestIndexByHash[hash] {
                let existing = tasks[existingIndex]
                if task.downloadedBytes > existing.downloadedBytes {
                    indicesToRemove.insert(existingIndex)
                    bestIndexByHash[hash] = index
                } else {
                    indicesToRemove.insert(index)
                }
            } else {
                bestIndexByHash[hash] = index
            }
        }

        guard !indicesToRemove.isEmpty else { return }
        let sorted = indicesToRemove.sorted(by: >)
        for index in sorted where index < tasks.count {
            let removed = tasks.remove(at: index)
            if let engine = activeEngines[removed.id] {
                engine.stop()
                activeEngines.removeValue(forKey: removed.id)
            }
            pieceManagers.removeValue(forKey: removed.id)
            pieceStores.removeValue(forKey: removed.id)
            metadataByTask.removeValue(forKey: removed.id)
            cancelExecution(for: removed.id)
        }
        notifyTasksUpdated()
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

        if let resolvedHash {
            DownloadStorage.clearDownloadCancelled(infoHash: resolvedHash)
        }

        if let existingIndex = tasks.firstIndex(where: { task in
            guard task.state != .completed && task.state != .failed else { return false }
            if let resolvedHash,
               (task.infoHash ?? "").lowercased() == resolvedHash.lowercased() {
                return true
            }
            if !magnetURI.isEmpty, task.magnetURI == magnetURI {
                return true
            }
            return false
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

        if let resolvedHash,
           let artifact = DownloadDiskRecovery.findBest(
               infoHash: resolvedHash,
               roots: [downloadDirectory, DownloadStorage.defaultRootDirectory()],
               preferredTitle: title,
               preferredStorageDirectory: nil
           ) {
            TorrentLog.info(
                "[DownloadManager] resuming from disk — hash=\(resolvedHash.prefix(8))… dir=\"\(artifact.title)\" bytes=\(artifact.streamByteCount)"
            )
            let task = DownloadTask(
                tmdbId: tmdbId,
                mediaKind: mediaKind,
                title: title,
                magnetURI: magnetURI,
                quality: quality,
                hdrType: hdrType,
                infoHash: resolvedHash
            )
            var restored = task
            restored.storageDirectory = artifact.storageDirectory
            if let existingIndex = tasks.firstIndex(where: {
                ($0.infoHash ?? "").lowercased() == resolvedHash.lowercased()
            }) {
                let existingId = tasks[existingIndex].id
                mutateTask(taskId: existingId) { existing in
                    existing.storageDirectory = artifact.storageDirectory
                    existing.downloadedBytes = max(existing.downloadedBytes, artifact.streamByteCount)
                }
                resumeDownload(taskId: existingId)
                return existingId
            }
            tasks.append(restored)
            notifyTasksUpdated()
            persist(restored)
            scheduleExecuteDownload(
                taskId: restored.id,
                resume: true,
                existingBitmap: artifact.bitmap
            )
            return restored.id
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
        notifyTasksUpdated()
        persist(task)
        scheduleExecuteDownload(taskId: task.id, resume: false, existingBitmap: nil)
        return task.id
    }

    public func isReexporting(taskId: UUID) -> Bool {
        reexportingTaskIds.contains(taskId)
    }

    /// Fixes a broken export by re-assembling from on-disk stream data (no re-download when possible).
    public func repairCompletedDownload(taskId: UUID) {
        guard let task = currentTask(taskId: taskId) else { return }
        guard task.state == .completed || isReexporting(taskId: taskId) else { return }

        if let path = task.outputPath {
            try? FileManager.default.removeItem(atPath: path)
        }

        reexportingTaskIds.insert(taskId)
        mutateTask(taskId: taskId) { task in
            task.state = .downloading
            task.progress = 0.05
            task.speed = 0
            task.peerCount = 0
            task.outputPath = nil
            task.failureMessage = nil
        }
        if let task = currentTask(taskId: taskId) {
            persist(task)
        }

        cancelExecution(for: taskId)
        executionTasks[taskId] = Task { [weak self] in
            guard let self else { return }
            defer { self.reexportingTaskIds.remove(taskId) }
            let fixed = await self.attemptLocalReexport(taskId: taskId)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.executionTasks.removeValue(forKey: taskId)
                guard !fixed else { return }
                guard let task = self.currentTask(taskId: taskId) else { return }
                TorrentLog.warn("[DownloadManager] local re-export unavailable — resuming torrent for missing pieces")
                self.mutateTask(taskId: taskId) { task in
                    task.state = .queued
                    task.failureMessage = nil
                }
                if let task = self.currentTask(taskId: taskId) {
                    self.persist(task)
                }
                self.scheduleExecuteDownload(
                    taskId: taskId,
                    resume: true,
                    existingBitmap: self.restoredBitmap(for: task)
                )
            }
        }
    }

    public func retryDownload(taskId: UUID) {
        guard let task = currentTask(taskId: taskId) else { return }
        guard task.state == .failed else { return }

        if let engine = activeEngines[taskId] {
            engine.stop()
            activeEngines.removeValue(forKey: taskId)
        }

        mutateTask(taskId: taskId) { task in
            task.state = .queued
            task.failureMessage = nil
        }
        if let task = currentTask(taskId: taskId) {
            persist(task)
        }
        scheduleExecuteDownload(
            taskId: taskId,
            resume: true,
            existingBitmap: restoredBitmap(for: task)
        )
    }

    public func pauseDownload(taskId: UUID) {
        guard currentTask(taskId: taskId) != nil else { return }
        cancelExecution(for: taskId)
        mutateTask(taskId: taskId) { $0.state = .paused }
        if let engine = activeEngines[taskId] {
            engine.stop()
            activeEngines.removeValue(forKey: taskId)
        }
        if let task = currentTask(taskId: taskId) {
            persist(task)
        }
    }

    public func resumeDownload(taskId: UUID) {
        guard currentTask(taskId: taskId) != nil else { return }
        mutateTask(taskId: taskId) { $0.state = .downloading }
        guard let task = currentTask(taskId: taskId) else { return }
        persist(task)
        scheduleExecuteDownload(
            taskId: taskId,
            resume: true,
            existingBitmap: restoredBitmap(for: task)
        )
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
        guard let hash = task.infoHash else { return nil }
        if let dir = task.storageDirectory,
           let sidecar = DownloadBitmapPersistence.loadBitmap(infoHash: hash, in: dir) {
            return sidecar
        }
        if let legacyDir = DownloadStorage.legacyContainerStreamsDirectory(),
           let sidecar = DownloadBitmapPersistence.loadBitmap(infoHash: hash, in: legacyDir) {
            return sidecar
        }
        return nil
    }

    /// Re-assembles the completed file from `moviebox_*.stream` on disk (legacy container or download folder).
    private func finalizeCompletedDownload(
        exportedURL: URL,
        displayTitle: String,
        infoHash: String,
        storageDirectory: URL,
        store: PieceStore
    ) async {
        await store.closeHandles()
        DownloadStorage.purgeDownloadPayload(infoHash: infoHash, storageDirectory: storageDirectory)
        TorrentLog.info(
            "[DownloadManager] completed — \(exportedURL.lastPathComponent) (removed stream cache for \(infoHash.prefix(8))…)"
        )
    }

    private func updateReexportProgress(taskId: UUID, progress: Double, downloadedBytes: Int64? = nil) {
        mutateTask(taskId: taskId) { task in
            task.state = .downloading
            task.progress = min(0.98, max(0.05, progress))
            if let downloadedBytes {
                task.downloadedBytes = downloadedBytes
            }
        }
    }

    private func attemptLocalReexport(taskId: UUID) async -> Bool {
        guard let task = currentTask(taskId: taskId) else { return false }

        updateReexportProgress(taskId: taskId, progress: 0.08)

        guard let identity = DownloadIdentity.resolve(
            magnetURI: task.magnetURI,
            storedInfoHash: task.infoHash
        ) else { return false }

        let infoHash = identity.infoHash
        let safeTitle = task.title.replacingOccurrences(of: "/", with: "_")
        let outputDir: URL
        if let stored = task.storageDirectory {
            outputDir = stored
        } else {
            outputDir = downloadDirectory.appendingPathComponent(safeTitle, isDirectory: true)
            mutateTask(taskId: taskId) { $0.storageDirectory = outputDir }
        }

        do {
            try DownloadStorage.prepareDirectory(at: outputDir)
        } catch {
            TorrentLog.warn("[DownloadManager] re-export directory not writable — \(outputDir.path)")
            return false
        }

        adoptLegacyStreamIfNeeded(infoHash: infoHash, storageDirectory: outputDir)
        updateReexportProgress(taskId: taskId, progress: 0.2)
        guard let taskForBitmap = currentTask(taskId: taskId) else { return false }
        let bitmap = restoredBitmap(for: taskForBitmap)
        guard hasResumableStore(infoHash: infoHash, storageDirectory: outputDir, bitmap: bitmap) else {
            return false
        }

        let metadata: TorrentMetadata
        do {
            metadata = try await Task.detached(priority: .userInitiated) {
                try await TorrentMetadataFetcher.fetch(
                    infoHash: infoHash,
                    magnetTrackers: identity.magnetTrackers
                )
            }.value
        } catch {
            TorrentLog.warn("[DownloadManager] re-export metadata failed — \(error.localizedDescription)")
            return false
        }

        let target = TorrentStreamTarget.selectPrimary(from: metadata)
        mutateTask(taskId: taskId) { task in
            task.infoHash = infoHash
            task.storageDirectory = outputDir
            task.totalBytes = target.byteLength
        }
        updateReexportProgress(
            taskId: taskId,
            progress: 0.35,
            downloadedBytes: DownloadStorage.fileAllocatedBytes(
                at: outputDir.appendingPathComponent("moviebox_\(infoHash.lowercased()).stream")
            )
        )

        do {
            let store = try await PieceStore(
                infoHash: infoHash,
                pieceCount: metadata.pieceCount,
                pieceSize: metadata.pieceLength,
                totalSize: metadata.totalSize,
                storageDirectory: outputDir,
                existingBitmap: bitmap,
                recreateFile: false
            )

            TorrentLog.info(
                "[DownloadManager] re-exporting from on-disk stream — \(DownloadStorage.fileAllocatedBytes(at: store.storageURL)) bytes"
            )
            updateReexportProgress(
                taskId: taskId,
                progress: 0.55,
                downloadedBytes: DownloadStorage.fileAllocatedBytes(at: store.storageURL)
            )

            let displayTitle = currentTask(taskId: taskId)?.title ?? task.title
            let fileURL = try await TorrentFileAssembler.exportPrimaryFile(
                metadata: metadata,
                pieceStore: store,
                outputDirectory: outputDir,
                displayTitle: displayTitle
            )

            updateReexportProgress(
                taskId: taskId,
                progress: 0.9,
                downloadedBytes: target.byteLength
            )
            await finalizeCompletedDownload(
                exportedURL: fileURL,
                displayTitle: displayTitle,
                infoHash: infoHash,
                storageDirectory: outputDir,
                store: store
            )

            mutateTask(taskId: taskId) { task in
                task.state = .completed
                task.outputPath = fileURL.path
                task.progress = 1
                task.downloadedBytes = target.byteLength
                task.failureMessage = nil
            }
            if let task = currentTask(taskId: taskId) {
                persist(task)
            }
            TorrentLog.info("[DownloadManager] re-export succeeded — \(fileURL.lastPathComponent)")
            return true
        } catch {
            TorrentLog.warn("[DownloadManager] re-export failed — \(error.localizedDescription)")
            return false
        }
    }

    private func persistSnapshot(task: DownloadTask, pieceBitmap: Data) {
        guard let infoHash = task.infoHash else { return }
        let normalizedHash = infoHash.lowercased()
        let dir = task.storageDirectory?.path ?? downloadDirectory.path
        persistenceDelegate?.downloadManager(
            self,
            didUpdate: DownloadPersistenceSnapshot(
                taskId: task.id,
                infoHash: normalizedHash,
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
        guard let task = currentTask(taskId: taskId) else { return }
        let infoHash = resolvedInfoHash(for: task)

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

        if let infoHash {
            DownloadStorage.purgeDownloadPayload(
                infoHash: infoHash,
                storageDirectory: task.storageDirectory
            )
            DownloadStorage.markDownloadCancelled(infoHash: infoHash)
            persistenceDelegate?.downloadManager(self, didRemove: infoHash)
        } else if let directory = task.storageDirectory {
            try? FileManager.default.removeItem(at: directory)
        }

        tasks.removeAll(where: { $0.id == taskId })
        notifyTasksUpdated()
    }

    private func resolvedInfoHash(for task: DownloadTask) -> String? {
        if let hash = task.infoHash?.lowercased(), !hash.isEmpty {
            return hash
        }
        if let directory = task.storageDirectory {
            return DownloadStorage.infoHashFromStorageDirectory(directory)
        }
        return nil
    }

    public func removeCompleted(taskId: UUID) {
        if let task = tasks.first(where: { $0.id == taskId }), task.state == .completed {
            if let hash = task.infoHash {
                persistenceDelegate?.downloadManager(self, didRemove: hash)
            }
            tasks.removeAll(where: { $0.id == taskId })
            notifyTasksUpdated()
        }
    }

    private func executeDownload(taskId: UUID, resume: Bool, existingBitmap: Data?) async {
        guard !Task.isCancelled else { return }
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        var task = tasks[index]
        guard isRunnableState(task.state) else { return }

        mutateTask(taskId: taskId) { task in
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
        mutateTask(taskId: taskId) { $0.infoHash = infoHash }
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
        let outputDir = resolvedOutputDirectory(for: task, safeTitle: safeTitle, resume: resume)
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
        let streamTarget = TorrentStreamTarget.selectPrimary(from: metadata)
        mutateTask(taskId: taskId) { task in
            task.storageDirectory = outputDir
            task.totalBytes = streamTarget.byteLength
        }
        task.storageDirectory = outputDir

        if let hash = task.infoHash {
            adoptLegacyStreamIfNeeded(infoHash: hash, storageDirectory: outputDir)
        }

        let sidecarBitmap = task.infoHash.flatMap {
            DownloadBitmapPersistence.loadBitmap(infoHash: $0, in: outputDir)
        }
        let storeBitmap = resolvedStoreBitmap(
            resume: resume,
            taskId: taskId,
            task: task,
            existingBitmap: existingBitmap
        ) ?? sidecarBitmap
        let hasResumeData = hasResumableStore(
            infoHash: metadata.infoHash,
            storageDirectory: outputDir,
            bitmap: storeBitmap
        )
        let actuallyResume = resume || hasResumeData
        if hasResumeData, !resume {
            TorrentLog.info(
                "[DownloadManager] found on-disk progress — resuming hash=\(metadata.infoHash.prefix(8))… at \(outputDir.path)"
            )
        }

        do {
            let store: PieceStore
            if actuallyResume, pieceStores[taskId] != nil, let existing = pieceStores[taskId] {
                store = existing
            } else {
                store = try await PieceStore(
                    infoHash: metadata.infoHash,
                    pieceCount: metadata.pieceCount,
                    pieceSize: metadata.pieceLength,
                    totalSize: metadata.totalSize,
                    storageDirectory: outputDir,
                    existingBitmap: storeBitmap,
                    recreateFile: !actuallyResume
                )
                pieceStores[taskId] = store
            }

            let tailPieces = StreamTailPlanner.tailPieceIndicesForDownload(
                target: streamTarget,
                pieceLength: metadata.pieceLength,
                pieceCount: metadata.pieceCount
            )

            // Always rebuild — stream-scoped piece selection must match the primary file.
            let manager = PieceManager(
                pieceCount: metadata.pieceCount,
                pieceLength: metadata.pieceLength,
                totalSize: metadata.totalSize,
                piecesHash: metadata.pieces,
                streamFirstPiece: streamTarget.firstPieceIndex,
                streamLastPiece: streamTarget.lastPieceIndex,
                streamTailPieces: tailPieces.isEmpty
                    ? [streamTarget.lastPieceIndex]
                    : tailPieces,
                streamMediaByteOffset: streamTarget.byteOffset,
                streamMediaByteLength: streamTarget.byteLength
            )
            pieceManagers[taskId] = manager

            if actuallyResume {
                let bitmapForSeed: Data
                if let storeBitmap, !storeBitmap.isEmpty {
                    bitmapForSeed = storeBitmap
                } else {
                    bitmapForSeed = await store.encodedBitmap()
                }
                await seedManagerFromResumedStore(
                    manager: manager,
                    store: store,
                    metadata: metadata,
                    taskId: taskId,
                    bitmapData: bitmapForSeed
                )
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

            // Resume or reconnect may already have every media piece on disk.
            await handleProgress(
                taskId: taskId,
                metadata: metadata,
                outputDir: outputDir,
                progress: await manager.progress(),
                speed: 0,
                peers: engine.livePeerCount()
            )

            guard shouldContinueExecution(for: taskId) else {
                engine.stop()
                activeEngines.removeValue(forKey: taskId)
                return
            }
            await persistCheckpoint(taskId: taskId)
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

    private func resolvedOutputDirectory(for task: DownloadTask, safeTitle: String, resume: Bool) -> URL {
        if resume, let stored = task.storageDirectory {
            return stored
        }
        if let stored = task.storageDirectory {
            if FileManager.default.fileExists(atPath: stored.path) {
                return stored
            }
            if let hash = task.infoHash,
               DownloadBitmapPersistence.loadBitmap(infoHash: hash, in: stored) != nil {
                return stored
            }
        }
        return downloadDirectory.appendingPathComponent(safeTitle, isDirectory: true)
    }

    private func resolvedStoreBitmap(
        resume: Bool,
        taskId: UUID,
        task: DownloadTask,
        existingBitmap: Data?
    ) -> Data? {
        if let existingBitmap, !existingBitmap.isEmpty {
            return existingBitmap
        }
        if let hash = task.infoHash {
            if let dir = task.storageDirectory,
               let sidecar = DownloadBitmapPersistence.loadBitmap(infoHash: hash, in: dir) {
                return sidecar
            }
            if let artifact = DownloadDiskRecovery.find(
                infoHash: hash,
                under: downloadDirectory,
                preferredTitle: task.title
            ) {
                return artifact.bitmap
            }
        }
        if resume, pieceStores[taskId] != nil {
            return nil
        }
        return nil
    }

    private func hasResumableStore(
        infoHash: String,
        storageDirectory: URL,
        bitmap: Data?
    ) -> Bool {
        let stream = storageDirectory.appendingPathComponent("moviebox_\(infoHash.lowercased()).stream")
        guard FileManager.default.fileExists(atPath: stream.path) else { return false }
        let allocated = DownloadStorage.fileAllocatedBytes(at: stream)
        if allocated > 1_000_000 { return true }
        return bitmap.map { !$0.isEmpty } ?? false
    }

    private func adoptLegacyStreamIfNeeded(infoHash: String, storageDirectory: URL) {
        guard let legacyDir = DownloadStorage.legacyContainerStreamsDirectory() else { return }
        let hash = infoHash.lowercased()
        let destination = storageDirectory.appendingPathComponent("moviebox_\(hash).stream")
        let legacy = legacyDir.appendingPathComponent("moviebox_\(hash).stream")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }

        let legacyBytes = DownloadStorage.fileAllocatedBytes(at: legacy)
        let currentBytes = DownloadStorage.fileAllocatedBytes(at: destination)
        guard legacyBytes > currentBytes + 10 * 1024 * 1024 else { return }

        TorrentLog.info(
            "[DownloadManager] adopting legacy stream — \(legacyBytes) bytes from container cache"
        )
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: legacy, to: destination)

        let legacyBitmap = DownloadBitmapPersistence.fileURL(infoHash: hash, in: legacyDir)
        let destinationBitmap = DownloadBitmapPersistence.fileURL(infoHash: hash, in: storageDirectory)
        if FileManager.default.fileExists(atPath: legacyBitmap.path) {
            try? FileManager.default.removeItem(at: destinationBitmap)
            try? FileManager.default.copyItem(at: legacyBitmap, to: destinationBitmap)
        }
    }

    private func seedManagerFromResumedStore(
        manager: PieceManager,
        store: PieceStore,
        metadata: TorrentMetadata,
        taskId: UUID,
        bitmapData: Data
    ) async {
        guard !bitmapData.isEmpty else { return }

        let target = TorrentStreamTarget.selectPrimary(from: metadata)
        let flags = PieceStore.decodeBitmap(bitmapData, pieceCount: metadata.pieceCount)
        var downloaded = Set<UInt32>()
        var verifiedInMediaSpan = 0
        for (idx, complete) in flags.enumerated() where complete {
            guard target.requiredPieceRange.contains(idx) else { continue }
            guard await store.hasPiece(idx) else { continue }
            downloaded.insert(UInt32(idx))
            verifiedInMediaSpan += 1
        }
        guard !downloaded.isEmpty else { return }

        await manager.setInitialDownloadedPieces(downloaded)
        let span = max(1, target.requiredPieceCount)
        let fraction = Double(verifiedInMediaSpan) / Double(span)
        mutateTask(taskId: taskId) { task in
            task.progress = max(task.progress, fraction)
            task.totalBytes = metadata.totalSize
            task.downloadedBytes = Int64(
                fraction * Double(target.byteLength)
            )
        }
        TorrentLog.info(
            "[DownloadManager] resumed \(verifiedInMediaSpan)/\(span) media pieces (\(Int(fraction * 100))%)"
        )
    }

    private func persistCheckpoint(taskId: UUID) async {
        guard let task = currentTask(taskId: taskId) else { return }
        guard let infoHash = task.infoHash, let dir = task.storageDirectory else {
            persistSnapshot(task: task, pieceBitmap: Data())
            return
        }
        guard let store = pieceStores[taskId] else {
            persistSnapshot(task: task, pieceBitmap: Data())
            return
        }
        let encoded = await store.encodedBitmap()
        DownloadBitmapPersistence.save(encoded, infoHash: infoHash, in: dir)
        persistSnapshot(task: task, pieceBitmap: encoded)
    }

    private func markFailed(taskId: UUID, message: String, log: String) {
        TorrentLog.warn(log)
        guard currentTask(taskId: taskId) != nil else { return }
        mutateTask(taskId: taskId) { task in
            task.state = .failed
            task.failureMessage = message
        }
        if let task = currentTask(taskId: taskId) {
            persist(task)
        }
    }

    private func currentTask(taskId: UUID) -> DownloadTask? {
        tasks.first(where: { $0.id == taskId })
    }

    /// Reassigns the task so `@Published` emits (in-place struct mutation does not).
    @discardableResult
    private func mutateTask(taskId: UUID, _ body: (inout DownloadTask) -> Void) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return false }
        var task = tasks[index]
        body(&task)
        tasks[index] = task
        notifyTasksUpdated()
        return true
    }

    private func notifyTasksUpdated() {
        onTasksUpdated?()
    }

    private func handleProgress(
        taskId: UUID,
        metadata: TorrentMetadata,
        outputDir: URL,
        progress: Double,
        speed: Double,
        peers: Int
    ) async {
        guard currentTask(taskId: taskId)?.state == .downloading else { return }

        let target = TorrentStreamTarget.selectPrimary(from: metadata)
        let store = pieceStores[taskId]
        let mediaProgress: Double
        if let store {
            mediaProgress = await store.progress(in: target.requiredPieceRange)
        } else {
            mediaProgress = progress
        }

        var shouldAssemble = false
        var mediaReadyForAssembly = false
        if mediaProgress >= 1.0, let store {
            mediaReadyForAssembly = await isMediaReadyForAssembly(
                store: store,
                target: target,
                metadata: metadata
            )
            if !mediaReadyForAssembly {
                await reconcileInflatedResumeProgress(
                    store: store,
                    manager: pieceManagers[taskId],
                    target: target,
                    metadata: metadata
                )
            } else {
                shouldAssemble = true
            }
        }

        let effectiveMediaProgress: Double
        if let store, mediaProgress >= 1.0, !mediaReadyForAssembly {
            effectiveMediaProgress = await store.progress(in: target.requiredPieceRange)
        } else {
            effectiveMediaProgress = mediaProgress
        }

        guard currentTask(taskId: taskId)?.state == .downloading else { return }

        mutateTask(taskId: taskId) { task in
            task.progress = max(task.progress, effectiveMediaProgress)
            task.speed = speed
            task.peerCount = peers
            let byteProgress = Int64(effectiveMediaProgress * Double(target.byteLength))
            task.downloadedBytes = max(task.downloadedBytes, byteProgress)
            task.totalBytes = target.byteLength
        }

        if !shouldAssemble, effectiveMediaProgress > 0.98, effectiveMediaProgress < 1.0, let store {
            let missing = await store.missingPieceIndices(in: target.requiredPieceRange)
            if !missing.isEmpty {
                TorrentLog.info(
                    "[DownloadManager] awaiting \(missing.count) media piece(s): \(missing.prefix(8).map(String.init).joined(separator: ","))\(missing.count > 8 ? "…" : "")"
                )
            }
        }

        if shouldAssemble, let store = pieceStores[taskId] {
            do {
                await store.syncToDisk()
                TorrentLog.info(
                    "[DownloadManager] assembling primary file — \(target.file.relativePath)"
                )
                let displayTitle = currentTask(taskId: taskId)?.title ?? ""
                let fileURL = try await TorrentFileAssembler.exportPrimaryFile(
                    metadata: metadata,
                    pieceStore: store,
                    outputDirectory: outputDir,
                    displayTitle: displayTitle
                )
                if let hash = tasks.first(where: { $0.id == taskId })?.infoHash {
                    await finalizeCompletedDownload(
                        exportedURL: fileURL,
                        displayTitle: displayTitle,
                        infoHash: hash,
                        storageDirectory: outputDir,
                        store: store
                    )
                } else {
                    await store.closeHandles()
                }
                pieceStores.removeValue(forKey: taskId)
                mutateTask(taskId: taskId) { task in
                    task.state = .completed
                    task.outputPath = fileURL.path
                    task.progress = 1
                    task.downloadedBytes = target.byteLength
                }
                activeEngines[taskId]?.stop()
                activeEngines.removeValue(forKey: taskId)
                pieceManagers.removeValue(forKey: taskId)
                metadataByTask.removeValue(forKey: taskId)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                TorrentLog.warn("[DownloadManager] assembly failed — \(message)")
                if let path = currentTask(taskId: taskId)?.outputPath {
                    try? FileManager.default.removeItem(atPath: path)
                }
                await reconcileInflatedResumeProgress(
                    store: store,
                    manager: pieceManagers[taskId],
                    target: target,
                    metadata: metadata
                )
                let resumedProgress = await store.progress(in: target.requiredPieceRange)
                mutateTask(taskId: taskId) { task in
                    task.state = .downloading
                    task.outputPath = nil
                    task.failureMessage = nil
                    task.progress = resumedProgress
                    task.downloadedBytes = Int64(resumedProgress * Double(target.byteLength))
                }
            }
        }

        await persistCheckpoint(taskId: taskId)
    }

    private func persist(_ task: DownloadTask) {
        guard task.infoHash != nil else { return }
        if pieceStores[task.id] != nil {
            Task { await self.persistCheckpoint(taskId: task.id) }
        } else {
            persistSnapshot(task: task, pieceBitmap: Data())
        }
    }

    private func isMediaReadyForAssembly(
        store: PieceStore,
        target: TorrentStreamTarget,
        metadata: TorrentMetadata
    ) async -> Bool {
        let missing = await store.missingPieceIndices(in: target.requiredPieceRange)
        guard missing.isEmpty else { return false }

        let allocated = DownloadStorage.fileAllocatedBytes(at: store.storageURL)
        let minimum = DownloadStorage.minimumOnDiskBytesForPieceSpan(
            firstPieceIndex: target.firstPieceIndex,
            lastPieceIndex: target.lastPieceIndex,
            pieceSize: metadata.pieceLength,
            totalSize: metadata.totalSize
        )
        guard allocated >= minimum else {
            TorrentLog.warn(
                "[DownloadManager] media bitmap complete but stream has only \(allocated) of \(minimum) required bytes on disk"
            )
            return false
        }
        return true
    }

    private func reconcileInflatedResumeProgress(
        store: PieceStore,
        manager: PieceManager?,
        target: TorrentStreamTarget,
        metadata: TorrentMetadata
    ) async {
        let allocated = DownloadStorage.fileAllocatedBytes(at: store.storageURL)
        let minimum = DownloadStorage.minimumOnDiskBytesForPieceSpan(
            firstPieceIndex: target.firstPieceIndex,
            lastPieceIndex: target.lastPieceIndex,
            pieceSize: metadata.pieceLength,
            totalSize: metadata.totalSize
        )
        guard allocated < minimum else { return }

        TorrentLog.warn(
            "[DownloadManager] clearing inflated resume bitmap — re-downloading \(target.requiredPieceCount) media piece(s)"
        )
        await store.clearVerifiedFlags(in: target.requiredPieceRange)
        await manager?.clearDownloadedPieces(in: target.requiredPieceRange)
    }
}
