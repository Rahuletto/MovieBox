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
        let ext = (target.file.relativePath as NSString).pathExtension
        let filename = ext.isEmpty ? safeName : "\(safeName).\(ext)"
        let destination = outputDirectory.appendingPathComponent(filename)

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
}

public enum TorrentFileAssemblerError: Error, LocalizedError {
    case incompleteExport

    public var errorDescription: String? {
        switch self {
        case .incompleteExport:
            "Download finished but the media file could not be assembled."
        }
    }
}
