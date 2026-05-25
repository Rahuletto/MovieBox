import Foundation

public enum DownloadStorageError: Error, LocalizedError {
    case permissionDenied(String)
    case notADirectory(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let path):
            "MovieBox does not have permission to save files in “\(path)”. Choose a folder in Settings → Downloads, or use the default Downloads/MovieBox folder."
        case .notADirectory(let path):
            "“\(path)” is not a folder."
        }
    }
}

/// Resolves and prepares on-disk download roots (tilde expansion, mkdir, write probe).
public enum DownloadStorage {
    /// Sandbox-friendly default (`~/Downloads/MovieBox` — matches downloads entitlement).
    public static func defaultRootDirectory() -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        return downloads.appendingPathComponent("MovieBox", isDirectory: true)
    }

    public static func resolveRootDirectory(path: String?) -> URL {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return defaultRootDirectory()
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    /// Creates the folder if needed and verifies the app can write a file inside it.
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

    private static func verifyWritable(_ directory: URL) throws {
        let probe = directory.appendingPathComponent(".moviebox-write-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probe) }
        guard FileManager.default.createFile(atPath: probe.path, contents: Data([0x00])) else {
            throw DownloadStorageError.permissionDenied(directory.path)
        }
    }
}
