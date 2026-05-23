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
    }

    public func completedFilePath(for infoHash: String) -> String? {
        let cleanHash = infoHash.lowercased()
        let descriptor = FetchDescriptor<DownloadRecord>(
            predicate: #Predicate<DownloadRecord> { $0.infoHash == cleanHash }
        )
        guard let record = try? modelContext.fetch(descriptor).first else { return nil }
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

        for record in records {
            let state = DownloadState(rawValue: record.state) ?? .queued
            guard state != .failed else { continue }

            let storageDir = URL(fileURLWithPath: record.storageDirectory ?? defaultStoragePath(for: record), isDirectory: true)
            guard !downloadManager.tasks.contains(where: { $0.infoHash == record.infoHash }) else { continue }
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
                pieceBitmap: record.pieceBitmap
            )
        }
    }

    public func downloadManager(_ manager: DownloadManager, didUpdate snapshot: DownloadPersistenceSnapshot) {
        let infoHash = snapshot.infoHash
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
        let descriptor = FetchDescriptor<DownloadRecord>(
            predicate: #Predicate { $0.infoHash == infoHash }
        )
        if let record = try? modelContext.fetch(descriptor).first {
            modelContext.delete(record)
            modelContext.saveOrReport(errorCenter, context: "Download remove")
        }
    }

    private func defaultStoragePath(for record: DownloadRecord) -> String {
        let safeTitle = record.title.replacingOccurrences(of: "/", with: "_")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/MovieBox/\(safeTitle)")
            .path
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
