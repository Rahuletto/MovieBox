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

/// On-disk download payload found under a MovieBox storage folder.
public struct RecoveredDownloadArtifact: Sendable {
    public let infoHash: String
    public let storageDirectory: URL
    public let title: String
    public let bitmap: Data
    public let streamByteCount: Int64
}

/// Locates in-progress `moviebox_*.stream` + `.bitmap` pairs for resume after DB loss or app restart.
public enum DownloadDiskRecovery {
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
        let stream = legacyDir.appendingPathComponent("moviebox_\(hash).stream")
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
            guard base.hasPrefix("moviebox_") else { continue }
            let hash = String(base.dropFirst("moviebox_".count)).lowercased()
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
