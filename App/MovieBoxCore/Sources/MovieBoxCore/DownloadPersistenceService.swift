import CoreStorage
import CoreStreaming
import Foundation
import SwiftData

@MainActor
public final class DownloadPersistenceService: DownloadPersistenceDelegate {
    private let modelContext: ModelContext
    private let errorCenter: AppErrorCenter

    public init(modelContext: ModelContext, errorCenter: AppErrorCenter) {
        self.modelContext = modelContext
        self.errorCenter = errorCenter
    }

    public func attach(to downloadManager: DownloadManager) {
        downloadManager.persistenceDelegate = self
        hydrate(into: downloadManager)
        recoverOrphanedDownloads(into: downloadManager)
        downloadManager.deduplicateTasks()
    }

    public func completedFilePath(for infoHash: String) -> String? {
        let cleanHash = infoHash.lowercased()
        let descriptor = FetchDescriptor<DownloadRecord>()
        guard let records = try? modelContext.fetch(descriptor) else { return nil }
        guard let record = records.first(where: { $0.infoHash.lowercased() == cleanHash }) else { return nil }
        guard record.state == DownloadState.completed.rawValue else { return nil }
        guard let path = record.localFilePath, !path.isEmpty else { return nil }
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    private func hydrate(into downloadManager: DownloadManager) {
        let descriptor = FetchDescriptor<DownloadRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        guard let records = try? modelContext.fetch(descriptor) else { return }
        var didMigratePaths = false

        for record in records {
            let state = DownloadState(rawValue: record.state) ?? .queued
            guard state != .failed else { continue }

            let storageDir = resolveStorageDirectory(for: record)
            if record.storageDirectory != storageDir.path {
                didMigratePaths = true
            }
            if let localPath = record.localFilePath,
               let migrated = migrateMovieBoxFilePath(
                   localPath,
                   from: DownloadStorage.sandboxDownloadsRootDirectory(),
                   to: DownloadStorage.defaultRootDirectory()
               ),
               migrated != localPath,
               FileManager.default.fileExists(atPath: migrated) {
                record.localFilePath = migrated
                didMigratePaths = true
            }
            let normalizedHash = record.infoHash.lowercased()
            guard !downloadManager.tasks.contains(where: {
                ($0.infoHash ?? "").lowercased() == normalizedHash
            }) else { continue }

            var bitmap = record.pieceBitmap
            if bitmap.isEmpty {
                bitmap = DownloadBitmapPersistence.loadBitmap(
                    infoHash: record.infoHash,
                    in: storageDir
                ) ?? Data()
            }

            downloadManager.restoreTask(
                id: stableTaskID(infoHash: record.infoHash),
                tmdbId: record.tmdbId,
                mediaKind: record.mediaKind,
                title: record.title,
                magnetURI: record.magnetURI,
                quality: record.quality,
                hdrType: record.hdrType,
                infoHash: record.infoHash,
                state: state,
                progress: record.progressFraction,
                totalBytes: record.totalBytes,
                downloadedBytes: record.downloadedBytes,
                localFilePath: record.localFilePath,
                storageDirectory: storageDir,
                pieceBitmap: bitmap.isEmpty ? nil : bitmap
            )
        }

        if didMigratePaths {
            modelContext.saveOrReport(errorCenter, context: "Download path migration")
        }
    }

    /// Re-attaches in-progress piece data when SwiftData has no row but `moviebox_*.stream` exists on disk.
    private func recoverOrphanedDownloads(into downloadManager: DownloadManager) {
        let roots = [
            downloadManager.downloadRootDirectory,
            DownloadStorage.defaultRootDirectory(),
            DownloadStorage.sandboxDownloadsRootDirectory(),
        ]
        var seenRoots = Set<String>()
        var activeHashes = Set(
            downloadManager.tasks.compactMap { $0.infoHash?.lowercased() }
        )

        for root in roots {
            let key = root.standardizedFileURL.path
            guard seenRoots.insert(key).inserted else { continue }

            var artifacts = DownloadDiskRecovery.scan(root: root)
            if let legacyDir = DownloadStorage.legacyContainerStreamsDirectory(),
               let streams = try? FileManager.default.contentsOfDirectory(
                   at: legacyDir,
                   includingPropertiesForKeys: nil,
                   options: [.skipsHiddenFiles]
               ) {
                for stream in streams where stream.pathExtension == "stream" {
                    let base = stream.deletingPathExtension().lastPathComponent
                    guard base.hasPrefix("moviebox_") else { continue }
                    let hash = String(base.dropFirst("moviebox_".count)).lowercased()
                    if let legacy = DownloadDiskRecovery.legacyContainerArtifact(
                        infoHash: hash,
                        preferredStorageDirectory: nil,
                        preferredTitle: nil
                    ), !artifacts.contains(where: { $0.infoHash == hash }) {
                        artifacts.append(legacy)
                    }
                }
            }

            for artifact in artifacts {
                let hash = artifact.infoHash
                guard activeHashes.insert(hash).inserted else { continue }
                guard !DownloadStorage.isDownloadCancelled(infoHash: hash) else { continue }

                let movie = fetchMovieRecord(infoHash: hash)
                let record: DownloadRecord
                if let existing = fetchDownloadRecord(infoHash: hash) {
                    record = existing
                    record.storageDirectory = artifact.storageDirectory.path
                    record.pieceBitmap = artifact.bitmap
                    record.downloadedBytes = max(record.downloadedBytes, artifact.streamByteCount)
                    if record.state == DownloadState.failed.rawValue {
                        record.state = DownloadState.paused.rawValue
                    }
                } else {
                    record = DownloadRecord(
                        infoHash: hash,
                        tmdbId: movie?.tmdbId ?? 0,
                        mediaKind: movie?.mediaKind ?? "movie",
                        title: movie?.title ?? artifact.title,
                        magnetURI: "",
                        quality: "1080p",
                        hdrType: nil,
                        localFilePath: nil,
                        storageDirectory: artifact.storageDirectory.path,
                        state: DownloadState.paused,
                        progressFraction: 0,
                        totalBytes: 0,
                        downloadedBytes: artifact.streamByteCount,
                        pieceBitmap: artifact.bitmap
                    )
                    modelContext.insert(record)
                }

                let storageDir = resolveStorageDirectory(for: record)
                let restoredState = DownloadState(rawValue: record.state) ?? .paused
                let state: DownloadState = restoredState == .completed ? .paused : restoredState

                downloadManager.restoreTask(
                    id: stableTaskID(infoHash: hash),
                    tmdbId: record.tmdbId,
                    mediaKind: record.mediaKind,
                    title: record.title,
                    magnetURI: record.magnetURI,
                    quality: record.quality,
                    hdrType: record.hdrType,
                    infoHash: hash,
                    state: state == .downloading || state == .queued ? .paused : state,
                    progress: record.progressFraction,
                    totalBytes: record.totalBytes,
                    downloadedBytes: max(record.downloadedBytes, artifact.streamByteCount),
                    localFilePath: record.localFilePath,
                    storageDirectory: storageDir,
                    pieceBitmap: artifact.bitmap
                )
            }
        }

        modelContext.saveOrReport(errorCenter, context: "Recovered downloads from disk")
    }

    private func fetchDownloadRecord(infoHash: String) -> DownloadRecord? {
        let normalized = infoHash.lowercased()
        let descriptor = FetchDescriptor<DownloadRecord>(
            predicate: #Predicate<DownloadRecord> { $0.infoHash == normalized }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func fetchMovieRecord(infoHash: String) -> MovieRecord? {
        let normalized = infoHash.lowercased()
        let descriptor = FetchDescriptor<MovieRecord>(
            predicate: #Predicate<MovieRecord> { $0.lastStreamInfoHash == normalized }
        )
        return try? modelContext.fetch(descriptor).first
    }

    public func downloadManager(_ manager: DownloadManager, didUpdate snapshot: DownloadPersistenceSnapshot) {
        let infoHash = snapshot.infoHash.lowercased()
        let descriptor = FetchDescriptor<DownloadRecord>(
            predicate: #Predicate<DownloadRecord> { $0.infoHash == infoHash }
        )
        let existing = try? modelContext.fetch(descriptor).first

        if let existing {
            existing.tmdbId = snapshot.tmdbId
            existing.mediaKind = snapshot.mediaKind
            existing.title = snapshot.title
            existing.magnetURI = snapshot.magnetURI
            existing.quality = snapshot.quality
            existing.hdrType = snapshot.hdrType
            existing.localFilePath = snapshot.localFilePath
            existing.storageDirectory = snapshot.storageDirectory
            existing.state = snapshot.state
            existing.progressFraction = snapshot.progress
            existing.totalBytes = snapshot.totalBytes
            existing.downloadedBytes = snapshot.downloadedBytes
            existing.pieceBitmap = snapshot.pieceBitmap
        } else {
            let record = DownloadRecord(
                infoHash: snapshot.infoHash,
                tmdbId: snapshot.tmdbId,
                mediaKind: snapshot.mediaKind,
                title: snapshot.title,
                magnetURI: snapshot.magnetURI,
                quality: snapshot.quality,
                hdrType: snapshot.hdrType,
                localFilePath: snapshot.localFilePath,
                storageDirectory: snapshot.storageDirectory,
                state: DownloadState(rawValue: snapshot.state) ?? .queued,
                progressFraction: snapshot.progress,
                totalBytes: snapshot.totalBytes,
                downloadedBytes: snapshot.downloadedBytes,
                pieceBitmap: snapshot.pieceBitmap
            )
            modelContext.insert(record)
        }
        modelContext.saveOrReport(errorCenter, context: "Download sync")
    }

    public func downloadManager(_ manager: DownloadManager, didRemove infoHash: String) {
        let normalized = infoHash.lowercased()
        let descriptor = FetchDescriptor<DownloadRecord>(
            predicate: #Predicate { $0.infoHash == normalized }
        )
        if let record = try? modelContext.fetch(descriptor).first {
            modelContext.delete(record)
            modelContext.saveOrReport(errorCenter, context: "Download remove")
        }
    }

    private func defaultStoragePath(for record: DownloadRecord) -> String {
        let safeTitle = record.title.replacingOccurrences(of: "/", with: "_")
        return DownloadStorage.defaultRootDirectory()
            .appendingPathComponent(safeTitle, isDirectory: true)
            .path
    }

    /// Uses the stored path, or the same folder under ~/Movies/MovieBox if the user moved data out of Downloads.
    private func resolveStorageDirectory(for record: DownloadRecord) -> URL {
        if let stored = record.storageDirectory, !stored.isEmpty {
            let storedURL = URL(fileURLWithPath: stored, isDirectory: true)
            if FileManager.default.fileExists(atPath: storedURL.path) {
                return storedURL
            }
            if let migrated = migrateMovieBoxFilePath(
                stored,
                from: DownloadStorage.sandboxDownloadsRootDirectory(),
                to: DownloadStorage.defaultRootDirectory()
            ) {
                let migratedURL = URL(fileURLWithPath: migrated, isDirectory: true)
                if FileManager.default.fileExists(atPath: migratedURL.path) {
                    record.storageDirectory = migrated
                    return migratedURL
                }
            }
            return storedURL
        }
        let fallback = URL(fileURLWithPath: defaultStoragePath(for: record), isDirectory: true)
        record.storageDirectory = fallback.path
        return fallback
    }

    private func migrateMovieBoxFilePath(
        _ path: String,
        from oldRoot: URL,
        to newRoot: URL
    ) -> String? {
        let old = oldRoot.standardizedFileURL.path
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard normalized == old || normalized.hasPrefix(old + "/") else { return nil }
        let suffix = String(normalized.dropFirst(old.count))
        return newRoot.standardizedFileURL.path + suffix
    }

    private func stableTaskID(infoHash: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var index = infoHash.startIndex
        var byteIndex = 0
        while index < infoHash.endIndex, byteIndex < 16 {
            let next = infoHash.index(index, offsetBy: 2, limitedBy: infoHash.endIndex) ?? infoHash.endIndex
            if let value = UInt8(infoHash[index..<next], radix: 16) {
                bytes[byteIndex] = value
                byteIndex += 1
            }
            index = next
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
