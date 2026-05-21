import Foundation

public enum TorrentFileAssembler {
    private static let chunkSize = 1024 * 1024

    public static func exportPrimaryFile(
        metadata: TorrentMetadata,
        pieceStorePath: URL,
        outputDirectory: URL
    ) throws -> URL {
        let target = TorrentStreamTarget.selectPrimary(from: metadata)
        let sourceURL = pieceStorePath
        let safeName = sanitizedFilename(metadata.name.isEmpty ? target.file.relativePath : metadata.name)
        // SECURITY: sanitize the extension sourced from the torrent's relativePath (peer-controlled)
        // before appending it to the output path to prevent path traversal (e.g. "../../bad.sh").
        let rawExt = (target.file.relativePath as NSString).pathExtension
        let safeExt = sanitizedExtension(rawExt)
        let filename = safeExt.isEmpty ? safeName : "\(safeName).\(safeExt)"
        let destination = outputDirectory.appendingPathComponent(filename)

        // SECURITY: Verify the resolved destination is inside the expected output directory.
        // appendingPathComponent handles ".." internally, but we double-check after resolution.
        let resolvedDest = destination.resolvingSymlinksInPath()
        let resolvedDir = outputDirectory.resolvingSymlinksInPath()
        guard resolvedDest.path.hasPrefix(resolvedDir.path + "/") ||
              resolvedDest.path == resolvedDir.path else {
            throw TorrentFileAssemblerError.pathTraversal(destination.path)
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)

        let readHandle = try FileHandle(forReadingFrom: sourceURL)
        let writeHandle = try FileHandle(forWritingTo: destination)
        defer {
            try? readHandle.close()
            try? writeHandle.close()
        }

        var offset = target.byteOffset
        var remaining = target.byteLength
        while remaining > 0 {
            let toRead = Int(min(Int64(chunkSize), remaining))
            try readHandle.seek(toOffset: UInt64(offset))
            let chunk = readHandle.readData(ofLength: toRead)
            guard chunk.count == toRead else {
                throw TorrentFileAssemblerError.incompleteExport
            }
            writeHandle.write(chunk)
            offset += Int64(chunk.count)
            remaining -= Int64(chunk.count)
        }

        return destination
    }

    private static func sanitizedFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "download" : String(trimmed.prefix(180))
    }

    /// Sanitizes a file extension from peer-controlled torrent metadata.
    /// Only allows alphanumeric characters and a maximum of 10 characters.
    private static func sanitizedExtension(_ raw: String) -> String {
        let allowed = raw.filter { $0.isLetter || $0.isNumber }
        return String(allowed.prefix(10)).lowercased()
    }
}

public enum TorrentFileAssemblerError: Error, LocalizedError {
    case incompleteExport
    case pathTraversal(String)

    public var errorDescription: String? {
        switch self {
        case .incompleteExport:
            "Download finished but the media file could not be assembled."
        case .pathTraversal(let path):
            "Torrent contains a file with an unsafe path: \(path)"
        }
    }
}
