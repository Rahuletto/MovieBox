import CoreStorage
import CoreStreaming
import CoreTorrent
import Foundation

@MainActor
public enum DownloadPlaybackPaths {
    /// Resolved on-disk media for a completed download (SwiftData, in-memory task, or both).
    public static func completedMediaPath(
        for infoHash: String,
        persistence: DownloadPersistenceService?,
        downloadManager: DownloadManager,
        downloadRecords: [DownloadRecord] = []
    ) -> String? {
        let hash = infoHash.lowercased()
        guard !hash.isEmpty else { return nil }

        if let path = persistence?.completedFilePath(for: hash),
           FileManager.default.fileExists(atPath: path) {
            return path
        }

        if let task = downloadManager.tasks.first(where: {
            ($0.infoHash ?? "").lowercased() == hash && $0.state == .completed
        }),
            let path = task.outputPath,
            FileManager.default.fileExists(atPath: path) {
            return path
        }

        if let record = downloadRecords.first(where: {
            $0.infoHash.lowercased() == hash
                && $0.state == DownloadState.completed.rawValue
        }),
            let path = record.localFilePath,
            !path.isEmpty,
            FileManager.default.fileExists(atPath: path) {
            return path
        }

        return nil
    }

    public static func completedMediaPath(
        for torrent: TorrentResult,
        persistence: DownloadPersistenceService?,
        downloadManager: DownloadManager,
        downloadRecords: [DownloadRecord] = []
    ) -> String? {
        guard let hash = torrent.resolvedInfoHash else { return nil }
        return completedMediaPath(
            for: hash,
            persistence: persistence,
            downloadManager: downloadManager,
            downloadRecords: downloadRecords
        )
    }
}
