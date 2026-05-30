import Foundation

/// Durable on-disk storage for in-progress stream sessions (piece bitmap + sparse `.stream` file).
public enum StreamSessionDiskStore {
    public static let folderName = "stream-sessions"

    public static func rootDirectory() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StreamSessionDiskStoreError.supportDirectoryUnavailable
        }
        let root = support
            .appendingPathComponent("MovieBox", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    public static func sessionDirectory(infoHash: String) throws -> URL {
        let normalized = infoHash.lowercased()
        guard !normalized.isEmpty else {
            throw StreamSessionDiskStoreError.invalidInfoHash
        }
        let directory = try rootDirectory().appendingPathComponent(normalized, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func bitmapURL(infoHash: String, in directory: URL? = nil) throws -> URL {
        let dir = try directory ?? sessionDirectory(infoHash: infoHash)
        return dir.appendingPathComponent(".moviebox_\(infoHash.lowercased()).bitmap")
    }

    public static func streamFileURL(infoHash: String, in directory: URL? = nil) throws -> URL {
        let dir = try directory ?? sessionDirectory(infoHash: infoHash)
        return dir.appendingPathComponent(".moviebox_\(infoHash.lowercased()).stream")
    }

    /// Deletes one stream session folder (sparse `.stream` + bitmap). Returns bytes reclaimed.
    @discardableResult
    public static func purgeSession(infoHash: String) -> Int64 {
        let hash = infoHash.lowercased()
        guard !hash.isEmpty else { return 0 }
        guard let directory = try? sessionDirectory(infoHash: hash) else { return 0 }
        let bytes = directoryAllocatedBytes(directory)
        try? FileManager.default.removeItem(at: directory)
        if bytes > 0 {
            TorrentLog.info("[Storage] purged stream session \(hash.prefix(8))… freed \(bytes / 1024 / 1024) MB")
        }
        return bytes
    }

    /// Removes every stream session except hashes in `retain` (usually empty — streaming cache only).
    @discardableResult
    public static func purgeAllSessions(retaining retain: Set<String> = []) -> Int64 {
        let normalizedRetain = Set(retain.map { $0.lowercased() }.filter { !$0.isEmpty })
        guard let root = try? rootDirectory(),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: root,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              )
        else { return 0 }

        var freed: Int64 = 0
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let hash = entry.lastPathComponent.lowercased()
            if normalizedRetain.contains(hash) { continue }
            freed += directoryAllocatedBytes(entry)
            try? FileManager.default.removeItem(at: entry)
        }
        if freed > 0 {
            TorrentLog.info("[Storage] purged stream-sessions freed \(freed / 1024 / 1024) MB")
        }
        return freed
    }

    /// One-time migration from legacy `tmp/moviebox_streams`, then delete the temp tree.
    @discardableResult
    public static func migrateLegacyTemporaryStoreIfNeeded(infoHash: String) -> Int64 {
        let hash = infoHash.lowercased()
        guard !hash.isEmpty else { return 0 }

        let legacyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moviebox_streams", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacyDir.path) else { return 0 }

        guard let targetDir = try? sessionDirectory(infoHash: hash) else { return 0 }

        let legacyBitmap = legacyDir.appendingPathComponent(".moviebox_\(hash).bitmap")
        let legacyStream = legacyDir.appendingPathComponent(".moviebox_\(hash).stream")
        let targetBitmap = targetDir.appendingPathComponent(".moviebox_\(hash).bitmap")
        let targetStream = targetDir.appendingPathComponent(".moviebox_\(hash).stream")

        if FileManager.default.fileExists(atPath: legacyBitmap.path),
           !FileManager.default.fileExists(atPath: targetBitmap.path) {
            try? FileManager.default.copyItem(at: legacyBitmap, to: targetBitmap)
        }
        if FileManager.default.fileExists(atPath: legacyStream.path),
           !FileManager.default.fileExists(atPath: targetStream.path) {
            try? FileManager.default.copyItem(at: legacyStream, to: targetStream)
        }
        return 0
    }

    /// Deletes the legacy temp streaming folder entirely (OS temp — should not hold multi-GB files).
    @discardableResult
    public static func purgeLegacyTemporaryStore() -> Int64 {
        let legacyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moviebox_streams", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacyDir.path) else { return 0 }
        let bytes = directoryAllocatedBytes(legacyDir)
        try? FileManager.default.removeItem(at: legacyDir)
        if bytes > 0 {
            TorrentLog.info("[Storage] purged legacy tmp/moviebox_streams freed \(bytes / 1024 / 1024) MB")
        }
        return bytes
    }

    public static func directoryAllocatedBytes(_ directory: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            if let allocated = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                .totalFileAllocatedSize {
                total += Int64(allocated)
            } else if let allocated = try? fileURL.resourceValues(forKeys: [.fileAllocatedSizeKey])
                .fileAllocatedSize {
                total += Int64(allocated)
            } else if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

public enum StreamSessionDiskStoreError: Error, Sendable {
    case supportDirectoryUnavailable
    case invalidInfoHash
}
