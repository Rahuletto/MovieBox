import CoreTorrent
import Foundation

public enum StreamFileOpenError: Error, LocalizedError {
    case notAFile
    case unrecognized
    case insufficientData

    public var errorDescription: String? {
        switch self {
        case .notAFile:
            "Choose a MovieBox stream file on disk."
        case .unrecognized:
            "This is not a MovieBox stream cache file (.moviebox_<hash>.stream)."
        case .insufficientData:
            "Not enough of this download is on disk to play yet. Open MovieBox and resume the download first."
        }
    }
}

/// Resolves `.moviebox_<infohash>.stream` sidecar files next to their `.bitmap`.
public enum StreamFileLocator {
    public static func isMovieBoxStreamFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return url.pathExtension.lowercased() == "stream"
            && infoHash(fromStreamFileName: url.lastPathComponent) != nil
    }

    public static func infoHash(fromStreamFileName name: String) -> String? {
        let base = (name as NSString).deletingPathExtension
        let newPrefix = ".moviebox_"
        let oldPrefix = "moviebox_"
        let hash: String
        if base.hasPrefix(newPrefix) {
            hash = String(base.dropFirst(newPrefix.count))
        } else if base.hasPrefix(oldPrefix) {
            hash = String(base.dropFirst(oldPrefix.count))
        } else {
            return nil
        }
        return MagnetURI.normalizeInfoHash(hash)
    }

    public static func artifact(at streamFileURL: URL) -> RecoveredDownloadArtifact? {
        guard isMovieBoxStreamFile(streamFileURL),
              FileManager.default.fileExists(atPath: streamFileURL.path)
        else { return nil }

        let directory = streamFileURL.deletingLastPathComponent()
        guard let parsedHash = infoHash(fromStreamFileName: streamFileURL.lastPathComponent) else {
            return nil
        }

        if let found = DownloadDiskRecovery.artifact(in: directory),
           found.infoHash == parsedHash {
            return found
        }

        let bitmap = DownloadBitmapPersistence.loadBitmap(infoHash: parsedHash, in: directory) ?? Data()
        let allocated = DownloadStorage.fileAllocatedBytes(at: streamFileURL)
        guard allocated > 0 else { return nil }

        return RecoveredDownloadArtifact(
            infoHash: parsedHash,
            storageDirectory: directory,
            title: directory.lastPathComponent,
            bitmap: bitmap,
            streamByteCount: allocated
        )
    }
}
