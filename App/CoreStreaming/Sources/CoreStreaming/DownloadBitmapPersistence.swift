import Foundation

/// Sidecar bitmap files so downloads can resume after a force-quit (SwiftData blob may lag).
public enum DownloadBitmapPersistence {
    public static func fileURL(infoHash: String, in storageDirectory: URL) -> URL {
        storageDirectory.appendingPathComponent("moviebox_\(infoHash.lowercased()).bitmap")
    }

    public static func save(_ data: Data, infoHash: String, in storageDirectory: URL) {
        guard !data.isEmpty else { return }
        let url = fileURL(infoHash: infoHash, in: storageDirectory)
        try? FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    public static func loadBitmap(infoHash: String, in storageDirectory: URL) -> Data? {
        let url = fileURL(infoHash: infoHash, in: storageDirectory)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty
        else { return nil }
        return data
    }

    public static func remove(infoHash: String, in storageDirectory: URL) {
        let url = fileURL(infoHash: infoHash, in: storageDirectory)
        try? FileManager.default.removeItem(at: url)
    }
}
