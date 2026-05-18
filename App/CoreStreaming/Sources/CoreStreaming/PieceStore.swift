import Foundation

// MARK: - Piece Store

public actor PieceStore {
    public let infoHash: String
    public let pieceCount: Int
    public let pieceSize: Int64
    public let totalSize: Int64
    public let storageURL: URL
    public let streamFirstPiece: Int

    private var bitmap: [Bool]
    private var writeHandle: FileHandle?
    private var readHandle: FileHandle?

    public init(
        infoHash: String,
        pieceCount: Int,
        pieceSize: Int64,
        totalSize: Int64? = nil,
        streamFirstPiece: Int = 0,
        storageDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws {
        self.infoHash = infoHash
        self.pieceCount = pieceCount
        self.pieceSize = pieceSize
        self.streamFirstPiece = streamFirstPiece
        let resolvedTotalSize = totalSize ?? Int64(pieceCount) * pieceSize
        self.totalSize = resolvedTotalSize
        self.storageURL = storageDirectory.appendingPathComponent("moviebox_\(infoHash).stream")
        self.bitmap = Array(repeating: false, count: pieceCount)

        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: storageURL.path) {
            try FileManager.default.removeItem(at: storageURL)
        }
        FileManager.default.createFile(atPath: storageURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: storageURL)
        try handle.truncate(atOffset: UInt64(resolvedTotalSize))
        self.writeHandle = handle
        self.readHandle = try FileHandle(forReadingFrom: storageURL)
    }

    public func write(pieceIndex: Int, data: Data) async throws {
        guard pieceIndex >= 0 && pieceIndex < pieceCount else {
            throw PieceStoreError.invalidPieceIndex(pieceIndex)
        }
        guard data.count <= pieceSize else {
            throw PieceStoreError.pieceTooLarge(data.count, pieceSize)
        }

        let offset = Int64(pieceIndex) * pieceSize
        try writeHandle?.seek(toOffset: UInt64(offset))
        writeHandle?.write(data)
        bitmap[pieceIndex] = true
        TorrentLog.debug("[PieceStore] Wrote piece \(pieceIndex) (\(data.count) bytes)")
    }

    public func read(offset: Int64, length: Int) async throws -> Data {
        let clampedLength = min(length, Int(totalSize - offset))
        guard offset >= 0, clampedLength > 0, offset < totalSize else {
            throw PieceStoreError.outOfRange(offset, totalSize)
        }

        let startPiece = Int(offset / pieceSize)
        let endPiece = Int((offset + Int64(clampedLength) - 1) / pieceSize)

        try await waitForPieces(from: startPiece, through: endPiece)

        guard let readHandle else {
            throw PieceStoreError.ioError("Read handle unavailable")
        }
        try readHandle.seek(toOffset: UInt64(offset))
        return readHandle.readData(ofLength: clampedLength)
    }

    public func hasPiece(_ index: Int) -> Bool {
        guard index >= 0 && index < bitmap.count else { return false }
        return bitmap[index]
    }

    public func hasRange(start: Int64, end: Int64) -> Bool {
        let startPiece = Int(start / pieceSize)
        let endPiece = Int(end / pieceSize)
        for i in startPiece...endPiece where !hasPiece(i) {
            return false
        }
        return true
    }

    public func progress() -> Double {
        guard pieceCount > 0 else { return 0 }
        let completed = bitmap.filter { $0 }.count
        return Double(completed) / Double(pieceCount)
    }

    /// Contiguous completed pieces starting at the stream's first piece (video file start).
    public func contiguousPiecesFromStart() -> Int {
        var count = 0
        for index in streamFirstPiece..<bitmap.count {
            guard bitmap[index] else { break }
            count += 1
        }
        return count
    }

    /// Bytes available contiguously from the stream's first piece (for progressive play readiness).
    public func contiguousBytesFromStreamStart() -> Int64 {
        var bytes: Int64 = 0
        for index in streamFirstPiece..<bitmap.count {
            guard bitmap[index] else { break }
            if index == pieceCount - 1 {
                bytes += totalSize - Int64(index) * pieceSize
            } else {
                bytes += pieceSize
            }
        }
        return bytes
    }

    public func cleanup() async {
        try? writeHandle?.close()
        try? readHandle?.close()
        writeHandle = nil
        readHandle = nil
        try? FileManager.default.removeItem(at: storageURL)
    }

    deinit {
        try? writeHandle?.close()
        try? readHandle?.close()
    }

    private func waitForPieces(from startPiece: Int, through endPiece: Int) async throws {
        var waitCount = 0
        while true {
            try Task.checkCancellation()
            var allAvailable = true
            for index in startPiece...endPiece {
                if !hasPiece(index) {
                    allAvailable = false
                    break
                }
            }
            if allAvailable { return }

            waitCount += 1
            if waitCount % 50 == 0 {
                TorrentLog.debug("[PieceStore] Waiting for pieces \(startPiece)-\(endPiece)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

public enum PieceStoreError: Error, LocalizedError {
    case invalidPieceIndex(Int)
    case pieceTooLarge(Int, Int64)
    case outOfRange(Int64, Int64)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPieceIndex(let index):
            "Invalid piece index: \(index)"
        case .pieceTooLarge(let size, let max):
            "Piece size \(size) exceeds maximum \(max)"
        case .outOfRange(let offset, let total):
            "Offset \(offset) out of range (total: \(total))"
        case .ioError(let message):
            "I/O error: \(message)"
        }
    }
}
