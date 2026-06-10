import Foundation

/// Sidecar bitmap files so downloads can resume after a force-quit (SwiftData blob may lag).
public enum DownloadBitmapPersistence {
    public static func fileURL(infoHash: String, in storageDirectory: URL) -> URL {
        storageDirectory.appendingPathComponent(".moviebox_\(infoHash.lowercased()).bitmap")
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

/// On-disk download payload found under a MovieBox storage folder.
public struct RecoveredDownloadArtifact: Sendable {
    public let infoHash: String
    public let storageDirectory: URL
    public let title: String
    public let bitmap: Data
    public let streamByteCount: Int64
}

/// A finished export sitting in a per-title download folder (no `.stream` sidecar left).
public struct RecoveredCompletedExport: Sendable, Equatable {
    public let infoHash: String
    public let storageDirectory: URL
    public let localFilePath: String
    public let title: String
    public let totalBytes: Int64

    public init(
        infoHash: String,
        storageDirectory: URL,
        localFilePath: String,
        title: String,
        totalBytes: Int64
    ) {
        self.infoHash = infoHash
        self.storageDirectory = storageDirectory
        self.localFilePath = localFilePath
        self.title = title
        self.totalBytes = totalBytes
    }
}

/// Locates in-progress `moviebox_*.stream` + `.bitmap` pairs for resume after DB loss or app restart.
public enum DownloadDiskRecovery {
    private static let exportExtensions: Set<String> = ["mp4", "mkv", "mov", "m4v", "avi", "webm"]

    /// Finds completed media exports when SwiftData rows were lost but `~/Movies/MovieBox/<Title>/` remains.
    public static func scanCompletedExports(root: URL) -> [RecoveredCompletedExport] {
        let rootURL = root.standardizedFileURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [RecoveredCompletedExport] = []
        var seenPaths = Set<String>()

        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            guard let media = largestExportFile(in: entry) else { continue }
            let path = media.path
            guard seenPaths.insert(path).inserted else { continue }

            let title = entry.lastPathComponent
            let bytes = (try? media.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let hash = stableInfoHash(for: path)
            results.append(
                RecoveredCompletedExport(
                    infoHash: hash,
                    storageDirectory: entry,
                    localFilePath: path,
                    title: title,
                    totalBytes: max(bytes, 0)
                )
            )
        }
        return results
    }

    private static func largestExportFile(in directory: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return files
            .filter { url in
                exportExtensions.contains(url.pathExtension.lowercased())
                    && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != false
            }
            .max { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let r = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return l < r
            }
    }

    /// Stable 40-char id derived from the on-disk export path (used when the torrent hash is unknown).
    private static func stableInfoHash(for localFilePath: String) -> String {
        let normalized = URL(fileURLWithPath: localFilePath).standardizedFileURL.path.lowercased()
        var bytes = [UInt8](repeating: 0, count: 20)
        for byte in normalized.utf8 {
            bytes[Int(byte) % 20] ^= byte
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func scan(root: URL) -> [RecoveredDownloadArtifact] {
        let rootURL = root.standardizedFileURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [RecoveredDownloadArtifact] = []
        var seenHashes = Set<String>()

        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            guard let artifact = artifact(in: entry), seenHashes.insert(artifact.infoHash).inserted else {
                continue
            }
            results.append(artifact)
        }
        return results
    }

    public static func find(
        infoHash: String,
        under root: URL,
        preferredTitle: String? = nil
    ) -> RecoveredDownloadArtifact? {
        let normalized = infoHash.lowercased()
        if let preferredTitle {
            let safe = preferredTitle.replacingOccurrences(of: "/", with: "_")
            let candidate = root.appendingPathComponent(safe, isDirectory: true)
            if let match = artifact(in: candidate), match.infoHash == normalized {
                return match
            }
        }
        return scan(root: root).first { $0.infoHash == normalized }
    }

    /// Picks the copy with the most real on-disk bytes (Movies folder vs legacy container cache).
    public static func findBest(
        infoHash: String,
        roots: [URL],
        preferredTitle: String?,
        preferredStorageDirectory: URL?
    ) -> RecoveredDownloadArtifact? {
        var best: RecoveredDownloadArtifact?
        for root in roots {
            guard let match = find(infoHash: infoHash, under: root, preferredTitle: preferredTitle) else {
                continue
            }
            if let best, best.streamByteCount >= match.streamByteCount { continue }
            best = match
        }
        if let legacy = legacyContainerArtifact(
            infoHash: infoHash,
            preferredStorageDirectory: preferredStorageDirectory,
            preferredTitle: preferredTitle
        ) {
            if let best, best.streamByteCount >= legacy.streamByteCount { return best }
            return legacy
        }
        return best
    }

    public static func legacyContainerArtifact(
        infoHash: String,
        preferredStorageDirectory: URL?,
        preferredTitle: String?
    ) -> RecoveredDownloadArtifact? {
        guard let legacyDir = DownloadStorage.legacyContainerStreamsDirectory() else { return nil }
        let hash = infoHash.lowercased()
        let stream = legacyDir.appendingPathComponent(".moviebox_\(hash).stream")
        guard FileManager.default.fileExists(atPath: stream.path) else { return nil }

        let allocated = DownloadStorage.fileAllocatedBytes(at: stream)
        guard allocated > 1_000_000 else { return nil }

        let storageDirectory: URL
        if let preferredStorageDirectory {
            storageDirectory = preferredStorageDirectory
        } else if let preferredTitle {
            let safe = preferredTitle.replacingOccurrences(of: "/", with: "_")
            storageDirectory = DownloadStorage.defaultRootDirectory()
                .appendingPathComponent(safe, isDirectory: true)
        } else {
            storageDirectory = legacyDir
        }

        let bitmap = DownloadBitmapPersistence.loadBitmap(infoHash: hash, in: storageDirectory) ?? Data()
        return RecoveredDownloadArtifact(
            infoHash: hash,
            storageDirectory: storageDirectory,
            title: preferredTitle ?? storageDirectory.lastPathComponent,
            bitmap: bitmap,
            streamByteCount: allocated
        )
    }

    public static func artifact(in directory: URL) -> RecoveredDownloadArtifact? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }

        for file in files where file.pathExtension == "stream" {
            let base = file.deletingPathExtension().lastPathComponent
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
            guard MagnetURI.normalizeInfoHash(hash) != nil else { continue }

            let bitmapURL = DownloadBitmapPersistence.fileURL(infoHash: hash, in: directory)
            guard FileManager.default.fileExists(atPath: bitmapURL.path),
                  let bitmap = try? Data(contentsOf: bitmapURL),
                  !bitmap.isEmpty
            else { continue }

            let allocated = DownloadStorage.fileAllocatedBytes(at: file)
            return RecoveredDownloadArtifact(
                infoHash: hash,
                storageDirectory: directory,
                title: directory.lastPathComponent,
                bitmap: bitmap,
                streamByteCount: allocated
            )
        }
        return nil
    }
}
