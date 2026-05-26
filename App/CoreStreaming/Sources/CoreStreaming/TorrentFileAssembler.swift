import Foundation

public enum TorrentFileAssembler {
    private static let chunkSize = 1024 * 1024

    /// Exports the primary video file after validating the on-disk stream (no SHA1 — avoids metadata traps).
    public static func exportPrimaryFile(
        metadata: TorrentMetadata,
        pieceStore: PieceStore,
        outputDirectory: URL,
        displayTitle: String? = nil,
        maxBytes: Int64? = nil
    ) async throws -> URL {
        let target = TorrentStreamTarget.selectPrimary(from: metadata)
        let exportLength = min(target.byteLength, maxBytes ?? target.byteLength)
        let videoExtension = (target.file.relativePath as NSString).pathExtension
        let filename: String
        if let displayTitle,
           !displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filename = displayFilename(forTitle: displayTitle, fileExtension: videoExtension)
        } else {
            filename = exportFilename(for: target)
        }
        let destination = outputDirectory.appendingPathComponent(filename)

        guard isContained(file: destination, in: outputDirectory) else {
            throw TorrentFileAssemblerError.pathTraversal(filename)
        }

        try await verifyRequiredPiecesStructurally(
            pieceStore: pieceStore,
            metadata: metadata,
            target: target,
            exportByteLength: exportLength
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)

        let writeHandle = try FileHandle(forWritingTo: destination)
        defer { try? writeHandle.close() }

        var mediaOffset: Int64 = 0
        while mediaOffset < exportLength {
            let toRead = Int(min(Int64(chunkSize), exportLength - mediaOffset))
            let torrentOffset = target.byteOffset + mediaOffset
            let data = try await pieceStore.read(offset: torrentOffset, length: toRead)
            guard data.count == toRead else {
                throw TorrentFileAssemblerError.incompleteExport
            }
            if mediaOffset == 0 {
                try validateLeadingMediaBytes(data, pathExtension: (target.file.relativePath as NSString).pathExtension)
            }
            writeHandle.write(data)
            mediaOffset += Int64(data.count)
        }

        try validateExportedMedia(at: destination, expectedLength: exportLength)
        return destination
    }

    /// Partial export for subtitle probing.
    public static func exportPrimaryFile(
        metadata: TorrentMetadata,
        pieceStorePath: URL,
        outputDirectory: URL,
        maxBytes: Int64
    ) async throws -> URL {
        let target = TorrentStreamTarget.selectPrimary(from: metadata)
        let filename = exportFilename(for: target)
        let destination = outputDirectory.appendingPathComponent(filename)

        guard isContained(file: destination, in: outputDirectory) else {
            throw TorrentFileAssemblerError.pathTraversal(filename)
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)

        let readHandle = try FileHandle(forReadingFrom: pieceStorePath)
        let writeHandle = try FileHandle(forWritingTo: destination)
        defer {
            try? readHandle.close()
            try? writeHandle.close()
        }

        var offset = target.byteOffset
        var remaining = min(target.byteLength, maxBytes)
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

    private static func mediaPieceSpan(
        metadata: TorrentMetadata,
        target: TorrentStreamTarget,
        exportByteLength: Int64
    ) throws -> ClosedRange<Int> {
        guard metadata.pieceLength > 0, metadata.pieceCount > 0 else {
            throw TorrentFileAssemblerError.incompleteExport
        }

        let exportEnd = target.byteOffset + exportByteLength
        let firstPiece = max(0, min(target.firstPieceIndex, metadata.pieceCount - 1))
        let lastByte = max(target.byteOffset, exportEnd - 1)
        let lastPiece = min(
            target.lastPieceIndex,
            metadata.pieceCount - 1,
            pieceIndexContaining(
                byteOffset: lastByte,
                pieceLength: metadata.pieceLength,
                pieceCount: metadata.pieceCount
            )
        )
        guard firstPiece <= lastPiece else {
            throw TorrentFileAssemblerError.missingPieces([firstPiece])
        }
        return firstPiece...lastPiece
    }

    private static func verifyRequiredPiecesStructurally(
        pieceStore: PieceStore,
        metadata: TorrentMetadata,
        target: TorrentStreamTarget,
        exportByteLength: Int64
    ) async throws {
        let span = try mediaPieceSpan(metadata: metadata, target: target, exportByteLength: exportByteLength)
        for pieceIndex in span {
            guard await pieceStore.hasPiece(pieceIndex) else {
                throw TorrentFileAssemblerError.missingPieces([pieceIndex])
            }
        }

        let allocated = DownloadStorage.fileAllocatedBytes(at: pieceStore.storageURL)
        let minimum = DownloadStorage.minimumOnDiskBytesForPieceSpan(
            firstPieceIndex: target.firstPieceIndex,
            lastPieceIndex: target.lastPieceIndex,
            pieceSize: metadata.pieceLength,
            totalSize: metadata.totalSize
        )
        guard allocated >= minimum else {
            throw TorrentFileAssemblerError.incompleteExport
        }

        let probeLength = Int(min(Int64(65_536), exportByteLength))
        let header = try await pieceStore.read(
            offset: target.byteOffset,
            length: probeLength
        )
        guard header.count == probeLength else {
            throw TorrentFileAssemblerError.incompleteExport
        }
        try validateLeadingMediaBytes(
            header,
            pathExtension: (target.file.relativePath as NSString).pathExtension
        )
        let sample = header.prefix(min(4096, header.count))
        guard !sample.isEmpty, sample.contains(where: { $0 != 0 }) else {
            throw TorrentFileAssemblerError.invalidContainer
        }
    }

    private static func pieceIndexContaining(
        byteOffset: Int64,
        pieceLength: Int64,
        pieceCount: Int
    ) -> Int {
        guard pieceLength > 0, pieceCount > 0 else { return 0 }
        let index64 = max(0, byteOffset) / pieceLength
        let clamped = min(index64, Int64(pieceCount - 1))
        return Int(clamped)
    }

    private static func validateLeadingMediaBytes(_ header: Data, pathExtension: String) throws {
        let ext = pathExtension.lowercased()
        guard ext == "mp4" || ext == "m4v" || ext == "mov" else { return }
        guard header.count >= 8 else {
            throw TorrentFileAssemblerError.invalidContainer
        }
        let boxType = header.subdata(in: 4..<8)
        guard boxType == Data("ftyp".utf8) else {
            throw TorrentFileAssemblerError.invalidContainer
        }
    }

    /// Rejects truncated exports and MP4s that are mostly zero-filled sparse holes.
    public static func validateExportedMedia(at url: URL, expectedLength: Int64) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size == expectedLength else {
            throw TorrentFileAssemblerError.sizeMismatch(expected: expectedLength, actual: size)
        }

        let ext = url.pathExtension.lowercased()
        guard ext == "mp4" || ext == "m4v" || ext == "mov" else { return }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = handle.readData(ofLength: 12)
        guard header.count >= 8 else {
            throw TorrentFileAssemblerError.invalidContainer
        }
        let boxType = header.subdata(in: 4..<8)
        guard boxType == Data("ftyp".utf8) else {
            throw TorrentFileAssemblerError.invalidContainer
        }
    }

    /// User-facing movie filename (from TMDB / download title), not the torrent release name.
    public static func displayFilename(forTitle title: String, fileExtension: String) -> String {
        let base = sanitizedFilename(title)
        let ext = sanitizedExtension(fileExtension)
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// Uses the video file name inside the torrent, not the top-level folder name.
    private static func exportFilename(for target: TorrentStreamTarget) -> String {
        let leaf = (target.file.relativePath as NSString).lastPathComponent
        let rawExt = (leaf as NSString).pathExtension
        return displayFilename(
            forTitle: (leaf as NSString).deletingPathExtension,
            fileExtension: rawExt
        )
    }

    private static func isContained(file: URL, in directory: URL) -> Bool {
        let parent = directory.standardizedFileURL
        let child = file.standardizedFileURL
        let parentComponents = parent.pathComponents
        let childComponents = child.pathComponents
        guard childComponents.count > parentComponents.count else { return false }
        return zip(parentComponents, childComponents).allSatisfy { $0 == $1 }
    }

    private static func sanitizedFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "download" : String(trimmed.prefix(180))
    }

    private static func sanitizedExtension(_ raw: String) -> String {
        let allowed = raw.filter { $0.isLetter || $0.isNumber }
        return String(allowed.prefix(10)).lowercased()
    }
}

public enum TorrentFileAssemblerError: Error, LocalizedError {
    case incompleteExport
    case pathTraversal(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case invalidContainer
    case pieceHashMismatch(Int)
    case missingPieces([Int])
    case missingPieceHash(Int)
    case invalidPiecesHashTable

    public var errorDescription: String? {
        switch self {
        case .incompleteExport:
            "Download finished but the media file could not be assembled."
        case .pathTraversal(let name):
            "Could not save “\(name)” — the torrent path is not allowed."
        case .sizeMismatch(let expected, let actual):
            "Assembled file is incomplete (\(actual) of \(expected) bytes). Resume the download to finish."
        case .invalidContainer:
            "Assembled file is damaged or incomplete. Resume the download — QuickTime cannot open it yet."
        case .pieceHashMismatch(let index):
            "Piece \(index) failed verification. Resume the download to fetch missing data."
        case .missingPieces(let indices):
            "Missing \(indices.count) piece(s) for the video file. Resume the download to finish."
        case .missingPieceHash(let index):
            "Torrent metadata is missing piece \(index) hashes. Try another release."
        case .invalidPiecesHashTable:
            "Torrent metadata is incomplete. Try another release."
        }
    }
}
