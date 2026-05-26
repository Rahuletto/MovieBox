import Foundation

public enum DownloadStorageError: Error, LocalizedError {
    case permissionDenied(String)
    case notADirectory(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let path):
            if DownloadStorage.isRunningInAppSandbox {
                """
                MovieBox cannot write to “\(path)”. For ~/Movies/MovieBox, rebuild after updating \
                (Movies entitlement). For other folders, use Settings → Downloads → Choose….
                """
            } else {
                "MovieBox does not have permission to save files in “\(path)”."
            }
        case .notADirectory(let path):
            "“\(path)” is not a folder."
        }
    }
}

/// Resolves and prepares on-disk download roots (tilde expansion, mkdir, write probe).
public enum DownloadStorage {
    /// True when the app runs inside the macOS App Sandbox (container home ≠ real user home).
    public static var isRunningInAppSandbox: Bool {
        FileManager.default.homeDirectoryForCurrentUser.path.contains("/Containers/")
    }

    /// User Movies folder (`com.apple.security.assets.movies.read-write` entitlement).
    public static func moviesLibraryDirectory() -> URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? realUserHomeDirectory().appendingPathComponent("Movies", isDirectory: true)
    }

    /// Preferred download root: `~/Movies/MovieBox`.
    public static func defaultRootDirectory() -> URL {
        moviesLibraryDirectory().appendingPathComponent("MovieBox", isDirectory: true)
    }

    /// Works with `com.apple.security.files.downloads.read-write` (no bookmark).
    public static func sandboxDownloadsRootDirectory() -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? realUserHomeDirectory().appendingPathComponent("Downloads", isDirectory: true)
        return downloads.appendingPathComponent("MovieBox", isDirectory: true)
    }

    public static func legacySandboxRootDirectory() -> URL {
        sandboxDownloadsRootDirectory()
    }

    /// Older builds stored piece files here (`~/Library/Containers/.../Data/tmp/moviebox_streams`).
    public static func legacyContainerStreamsDirectory() -> URL? {
        guard isRunningInAppSandbox else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("tmp/moviebox_streams", isDirectory: true)
    }

    /// Physical bytes on disk (not logical sparse length).
    public static func fileAllocatedBytes(at url: URL) -> Int64 {
        if let allocated = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            .totalFileAllocatedSize {
            return Int64(allocated)
        }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return Int64(size)
        }
        return 0
    }

    /// Minimum physical bytes expected when every piece in a span is present (guards sparse .stream holes).
    public static func minimumOnDiskBytesForPieceSpan(
        firstPieceIndex: Int,
        lastPieceIndex: Int,
        pieceSize: Int64,
        totalSize: Int64
    ) -> Int64 {
        let start = Int64(firstPieceIndex) * pieceSize
        let end = min(totalSize, Int64(lastPieceIndex + 1) * pieceSize)
        let span = max(0, end - start)
        return max(pieceSize, Int64(Double(span) * 0.92))
    }

    /// Fallback when the user picks a folder outside Movies/Downloads entitlements.
    public static func isEntitlementBackedPath(_ url: URL) -> Bool {
        isContained(url, in: moviesLibraryDirectory())
            || isContained(url, in: sandboxDownloadsRootDirectory().deletingLastPathComponent())
    }

    public static func realUserHomeDirectory() -> URL {
        if isRunningInAppSandbox {
            let user = NSUserName()
            if !user.isEmpty {
                return URL(fileURLWithPath: "/Users/\(user)", isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static func resolveRootDirectory(path: String?) -> URL {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return defaultRootDirectory()
        }
        if trimmed == "~" || trimmed.hasPrefix("~/") || trimmed.hasPrefix("~") {
            let home = realUserHomeDirectory().path
            let expanded = (trimmed as NSString).replacingOccurrences(of: "~", with: home)
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    public static func prepareDirectory(at url: URL) throws {
        let resolved = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw DownloadStorageError.notADirectory(resolved.path)
            }
        } else {
            try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        }
        try verifyWritable(resolved)
    }

    public static func isContained(_ child: URL, in parent: URL) -> Bool {
        let parentURL = parent.standardizedFileURL
        let childURL = child.standardizedFileURL
        if parentURL == childURL { return true }
        let parentComponents = parentURL.pathComponents
        let childComponents = childURL.pathComponents
        guard childComponents.count >= parentComponents.count else { return false }
        return zip(parentComponents, childComponents).allSatisfy { $0 == $1 }
    }

    private static func verifyWritable(_ directory: URL) throws {
        let probe = directory.appendingPathComponent(".moviebox-write-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probe) }
        guard FileManager.default.createFile(atPath: probe.path, contents: Data([0x00])) else {
            throw DownloadStorageError.permissionDenied(directory.path)
        }
    }

    private static func appSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("MovieBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var cancelledHashesFile: URL {
        appSupportDirectory().appendingPathComponent("cancelled-info-hashes.json")
    }

    public static func markDownloadCancelled(infoHash: String) {
        let hash = infoHash.lowercased()
        var cancelled = loadCancelledHashes()
        guard cancelled.insert(hash).inserted else { return }
        saveCancelledHashes(cancelled)
    }

    public static func isDownloadCancelled(infoHash: String) -> Bool {
        loadCancelledHashes().contains(infoHash.lowercased())
    }

    public static func clearDownloadCancelled(infoHash: String) {
        let hash = infoHash.lowercased()
        var cancelled = loadCancelledHashes()
        guard cancelled.remove(hash) != nil else { return }
        saveCancelledHashes(cancelled)
    }

    public static func purgeDownloadPayload(infoHash: String, storageDirectory: URL?) {
        let hash = infoHash.lowercased()
        if let storageDirectory {
            removePayloadFiles(infoHash: hash, in: storageDirectory)
        }
        if let legacyDir = legacyContainerStreamsDirectory() {
            removePayloadFiles(infoHash: hash, in: legacyDir)
        }
    }

    public static func infoHashFromStorageDirectory(_ directory: URL) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for file in files where file.pathExtension == "stream" {
            let base = file.deletingPathExtension().lastPathComponent
            guard base.hasPrefix("moviebox_") else { continue }
            let hash = String(base.dropFirst("moviebox_".count)).lowercased()
            if MagnetURI.normalizeInfoHash(hash) != nil {
                return hash
            }
        }
        return nil
    }

    private static func removePayloadFiles(infoHash: String, in directory: URL) {
        let stream = directory.appendingPathComponent("moviebox_\(infoHash).stream")
        let bitmap = directory.appendingPathComponent("moviebox_\(infoHash).bitmap")
        try? FileManager.default.removeItem(at: stream)
        try? FileManager.default.removeItem(at: bitmap)
    }

    private static func loadCancelledHashes() -> Set<String> {
        guard let data = try? Data(contentsOf: cancelledHashesFile),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(decoded.map { $0.lowercased() })
    }

    private static func saveCancelledHashes(_ hashes: Set<String>) {
        guard let data = try? JSONEncoder().encode(Array(hashes).sorted()) else { return }
        try? data.write(to: cancelledHashesFile, options: .atomic)
    }
}
