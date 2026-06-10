import CoreMetadata
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

    /// Re-attaches in-progress piece data when SwiftData has no row but `.moviebox_*.stream` exists on disk.
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
        recoverCompletedExports(into: downloadManager, activeHashes: &activeHashes)

        for root in roots {
            let key = root.standardizedFileURL.path
            guard seenRoots.insert(key).inserted else { continue }

            var artifacts = DownloadDiskRecovery.scan(root: root)
            if let legacyDir = DownloadStorage.legacyContainerStreamsDirectory(),
               let streams = try? FileManager.default.contentsOfDirectory(
                   at: legacyDir,
                   includingPropertiesForKeys: nil,
                   options: []
               ) {
                for stream in streams where stream.pathExtension == "stream" {
                    let base = stream.deletingPathExtension().lastPathComponent
                    let newPrefix = ".moviebox_"
                    let oldPrefix = "moviebox_"
                    let prefix: String
                    if base.hasPrefix(newPrefix) {
                        prefix = newPrefix
                    } else if base.hasPrefix(oldPrefix) {
                        prefix = oldPrefix
                    } else {
                        continue
                    }
                    let hash = String(base.dropFirst(prefix.count)).lowercased()
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

    /// Re-imports finished `.mp4`/`.mkv` files when SwiftData rows were wiped but `~/Movies/MovieBox/<Title>/` remains.
    private func recoverCompletedExports(
        into downloadManager: DownloadManager,
        activeHashes: inout Set<String>
    ) {
        let roots = [
            downloadManager.downloadRootDirectory,
            DownloadStorage.defaultRootDirectory(),
            DownloadStorage.sandboxDownloadsRootDirectory(),
        ]
        var seenPaths = Set<String>()

        for root in roots {
            for export in DownloadDiskRecovery.scanCompletedExports(root: root) {
                guard seenPaths.insert(export.localFilePath).inserted else { continue }

                let hash = resolvedInfoHash(for: export) ?? export.infoHash
                guard activeHashes.insert(hash).inserted else { continue }
                guard !DownloadStorage.isDownloadCancelled(infoHash: hash) else { continue }

                let movie = movieRecord(matchingTitle: export.title)
                let record: DownloadRecord
                if let existing = fetchDownloadRecord(infoHash: hash) {
                    record = existing
                } else {
                    record = DownloadRecord(
                        infoHash: hash,
                        tmdbId: movie?.tmdbId ?? 0,
                        mediaKind: movie?.mediaKind ?? "movie",
                        title: export.title,
                        magnetURI: "",
                        quality: "1080p",
                        hdrType: nil,
                        localFilePath: export.localFilePath,
                        storageDirectory: export.storageDirectory.path,
                        state: .completed,
                        progressFraction: 1,
                        totalBytes: export.totalBytes,
                        downloadedBytes: export.totalBytes
                    )
                    modelContext.insert(record)
                }

                record.storageDirectory = export.storageDirectory.path
                record.localFilePath = export.localFilePath
                record.state = DownloadState.completed.rawValue
                record.progressFraction = 1
                record.totalBytes = max(record.totalBytes, export.totalBytes)
                record.downloadedBytes = max(record.downloadedBytes, export.totalBytes)
                if record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    record.title = export.title
                }
                if record.tmdbId == 0, let movie {
                    record.tmdbId = movie.tmdbId
                    record.mediaKind = movie.mediaKind
                }

                downloadManager.restoreTask(
                    id: stableTaskID(infoHash: hash),
                    tmdbId: record.tmdbId,
                    mediaKind: record.mediaKind,
                    title: record.title,
                    magnetURI: record.magnetURI,
                    quality: record.quality,
                    hdrType: record.hdrType,
                    infoHash: hash,
                    state: .completed,
                    progress: 1,
                    totalBytes: record.totalBytes,
                    downloadedBytes: record.downloadedBytes,
                    localFilePath: export.localFilePath,
                    storageDirectory: export.storageDirectory,
                    pieceBitmap: nil
                )
            }
        }
    }

    private func resolvedInfoHash(for export: RecoveredCompletedExport) -> String? {
        if let movie = movieRecord(matchingTitle: export.title),
           let hash = movie.lastStreamInfoHash?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hash.isEmpty {
            return hash.lowercased()
        }
        return nil
    }

    private func movieRecord(matchingTitle title: String) -> MovieRecord? {
        let needle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        let descriptor = FetchDescriptor<MovieRecord>()
        guard let records = try? modelContext.fetch(descriptor) else { return nil }
        return records.first { record in
            record.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
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
        let priorState = existing?.state

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
            if !snapshot.selectedSubtitleID.isEmpty {
                existing.selectedSubtitleID = snapshot.selectedSubtitleID
            }
            if let path = snapshot.localSubtitlePath {
                existing.localSubtitlePath = path
            }
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
                pieceBitmap: snapshot.pieceBitmap,
                selectedSubtitleID: snapshot.selectedSubtitleID,
                localSubtitlePath: snapshot.localSubtitlePath
            )
            modelContext.insert(record)
        }
        modelContext.saveOrReport(errorCenter, context: "Download sync")

        if snapshot.state == DownloadState.completed.rawValue,
           priorState != DownloadState.completed.rawValue {
            Task { await downloadSubtitleBesideCompletedMedia(snapshot: snapshot) }
        }
    }

    private func downloadSubtitleBesideCompletedMedia(snapshot: DownloadPersistenceSnapshot) async {
        guard snapshot.tmdbId > 0 else { return }
        if let path = snapshot.localSubtitlePath,
           !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            return
        }

        let storageDir = URL(fileURLWithPath: snapshot.storageDirectory, isDirectory: true)
        guard FileManager.default.fileExists(atPath: storageDir.path) else { return }

        guard let settings = try? modelContext.fetch(FetchDescriptor<AppSettings>()).first,
              let mode = settings.subtitleServiceMode
        else { return }

        let kind = MediaKind(storageValue: snapshot.mediaKind) ?? .movie
        let movieRecord = fetchMovieRecord(tmdbId: snapshot.tmdbId)
        let scope = subtitleScope(for: kind, movieRecord: movieRecord)
        let downloadRecord = fetchDownloadRecord(infoHash: snapshot.infoHash)

        do {
            let metadata = MetadataClient(mode: mode)
            let detail = try await metadata.movieDetail(id: snapshot.tmdbId, kind: kind)
            let subtitleClient = SubtitleClient(mode: mode)
            let season = kind == .tv ? (scope.season > 0 ? scope.season : nil) : nil
            let episode = kind == .tv ? (scope.episode > 0 ? scope.episode : nil) : nil
            let results = try await subtitleClient.searchSubtitles(
                title: detail.movie.title,
                year: Int(detail.movie.releaseDate.prefix(4)),
                language: "all",
                type: kind == .tv ? "tv" : "movie",
                imdbId: detail.imdbId,
                tmdbId: snapshot.tmdbId,
                seasonNumber: season,
                episodeNumber: episode
            )
            guard !results.isEmpty else { return }

            let subtitle: SubtitleInfo
            if let movieRecord,
               let saved = SubtitlePreferenceStore.savedPreference(record: movieRecord, scope: scope),
               let match = results.first(where: { $0.id == saved.id }) {
                subtitle = match
            } else {
                subtitle = results[0]
            }

            _ = await SubtitlePreferenceStore.attachSubtitleToDownload(
                subtitle: subtitle,
                mode: mode,
                storageDirectory: storageDir,
                mediaFilePath: snapshot.localFilePath,
                tmdbId: snapshot.tmdbId,
                scope: scope,
                downloadRecord: downloadRecord,
                movieRecord: movieRecord,
                modelContext: modelContext
            )
        } catch {
            NSLog("Subtitle download beside completed media failed: \(error.localizedDescription)")
        }
    }

    private func fetchMovieRecord(tmdbId: Int) -> MovieRecord? {
        let descriptor = FetchDescriptor<MovieRecord>(
            predicate: #Predicate<MovieRecord> { $0.tmdbId == tmdbId }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func subtitleScope(for kind: MediaKind, movieRecord: MovieRecord?) -> SubtitlePreferenceStore.Scope {
        guard kind == .tv, let movieRecord else { return .movie() }
        if movieRecord.lastSubtitleSeason > 0, movieRecord.lastSubtitleEpisode > 0 {
            return .tv(
                season: movieRecord.lastSubtitleSeason,
                episode: movieRecord.lastSubtitleEpisode
            )
        }
        if movieRecord.lastWatchedSeason > 0, movieRecord.lastWatchedEpisode > 0 {
            return .tv(
                season: movieRecord.lastWatchedSeason,
                episode: movieRecord.lastWatchedEpisode
            )
        }
        return .movie()
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
