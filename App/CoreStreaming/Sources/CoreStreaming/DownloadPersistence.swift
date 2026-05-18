import Foundation

public struct DownloadPersistenceSnapshot: Sendable {
    public let taskId: UUID
    public let infoHash: String
    public let tmdbId: Int
    public let mediaKind: String
    public let title: String
    public let magnetURI: String
    public let quality: String
    public let hdrType: String?
    public let state: String
    public let progress: Double
    public let totalBytes: Int64
    public let downloadedBytes: Int64
    public let localFilePath: String?
    public let pieceBitmap: Data
    public let storageDirectory: String

    public init(
        taskId: UUID,
        infoHash: String,
        tmdbId: Int,
        mediaKind: String,
        title: String,
        magnetURI: String,
        quality: String,
        hdrType: String?,
        state: String,
        progress: Double,
        totalBytes: Int64,
        downloadedBytes: Int64,
        localFilePath: String?,
        pieceBitmap: Data,
        storageDirectory: String
    ) {
        self.taskId = taskId
        self.infoHash = infoHash
        self.tmdbId = tmdbId
        self.mediaKind = mediaKind
        self.title = title
        self.magnetURI = magnetURI
        self.quality = quality
        self.hdrType = hdrType
        self.state = state
        self.progress = progress
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.localFilePath = localFilePath
        self.pieceBitmap = pieceBitmap
        self.storageDirectory = storageDirectory
    }
}

@MainActor
public protocol DownloadPersistenceDelegate: AnyObject {
    func downloadManager(_ manager: DownloadManager, didUpdate snapshot: DownloadPersistenceSnapshot)
    func downloadManager(_ manager: DownloadManager, didRemove infoHash: String)
}
