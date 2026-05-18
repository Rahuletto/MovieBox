import Foundation

// MARK: - Piece Store

public actor PieceStore {
    public let infoHash: String
    public let pieceCount: Int
    public let pieceSize: Int64
    public let totalSize: Int64
    public let storageURL: URL

    private var bitmap: [Bool]
    private var fileHandle: FileHandle?

    public init(infoHash: String, pieceCount: Int, pieceSize: Int64, storageDirectory: URL = FileManager.default.temporaryDirectory) async throws {
        self.infoHash = infoHash
        self.pieceCount = pieceCount
        self.pieceSize = pieceSize
        self.totalSize = Int64(pieceCount) * pieceSize
        self.storageURL = storageDirectory.appendingPathComponent("moviebox_\(infoHash).stream")
        self.bitmap = Array(repeating: false, count: pieceCount)

        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: storageURL.path) {
            try FileManager.default.removeItem(at: storageURL)
        }
        FileManager.default.createFile(atPath: storageURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: storageURL)
        try handle.truncate(atOffset: UInt64(totalSize))
        self.fileHandle = handle
    }

    public func write(pieceIndex: Int, data: Data) async throws {
        guard pieceIndex >= 0 && pieceIndex < pieceCount else {
            throw PieceStoreError.invalidPieceIndex(pieceIndex)
        }
        guard data.count <= pieceSize else {
            throw PieceStoreError.pieceTooLarge(data.count, pieceSize)
        }

        let offset = Int64(pieceIndex) * pieceSize
        NSLog("[PieceStore] 💾 Writing piece \(pieceIndex) on disk (offset: \(offset), size: \(data.count) bytes)")
        try fileHandle?.seek(toOffset: UInt64(offset))
        fileHandle?.write(data)
        bitmap[pieceIndex] = true
        NSLog("[PieceStore] ✅ Successfully wrote piece \(pieceIndex) to disk. Bitmap progress: \(String(format: "%.1f", progress() * 100))%")
    }

    public func read(offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0 && offset < totalSize else {
            throw PieceStoreError.outOfRange(offset, totalSize)
        }

        let startPiece = Int(offset / pieceSize)
        let endPiece = Int((offset + Int64(length) - 1) / pieceSize)

        NSLog("[PieceStore] 🔍 Read requested: offset \(offset), length \(length) (requires pieces \(startPiece) to \(endPiece))")

        // Wait asynchronously until the requested piece range is downloaded and written on disk
        var waitCount = 0
        while true {
            try Task.checkCancellation()
            var allAvailable = true
            for i in startPiece...endPiece {
                if !hasPiece(i) {
                    allAvailable = false
                    break
                }
            }
            if allAvailable {
                break
            }
            waitCount += 1
            if waitCount % 50 == 0 { // Log once every 5 seconds (50 * 100ms)
                NSLog("[PieceStore] ⏳ Still waiting for pieces \(startPiece)-\(endPiece) to download... (elapsed: \(waitCount * 100)ms)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        if waitCount > 0 {
            NSLog("[PieceStore] 🎉 Pieces \(startPiece)-\(endPiece) successfully acquired after waiting \(waitCount * 100)ms!")
        }

        let readHandle = try FileHandle(forReadingFrom: storageURL)
        try readHandle.seek(toOffset: UInt64(offset))
        let data = readHandle.readData(ofLength: length)
        try readHandle.close()
        return data
    }

    public func hasPiece(_ index: Int) -> Bool {
        guard index >= 0 && index < bitmap.count else { return false }
        return bitmap[index]
    }

    public func hasRange(start: Int64, end: Int64) -> Bool {
        let startPiece = Int(start / pieceSize)
        let endPiece = Int(end / pieceSize)
        for i in startPiece...endPiece {
            if !hasPiece(i) { return false }
        }
        return true
    }

    public func progress() -> Double {
        let completed = bitmap.filter { $0 }.count
        return Double(completed) / Double(pieceCount)
    }

    public func contiguousPiecesFromStart() -> Int {
        var count = 0
        for hasPiece in bitmap {
            guard hasPiece else { break }
            count += 1
        }
        return count
    }

    public func cleanup() async {
        try? fileHandle?.close()
        try? FileManager.default.removeItem(at: storageURL)
    }

    deinit {
        try? fileHandle?.close()
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
