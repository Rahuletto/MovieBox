import Foundation

// MARK: - Piece Store

public actor PieceStore {
    public let infoHash: String
    public let pieceCount: Int
    public let pieceSize: Int64
    public let totalSize: Int64
    public let storageURL: URL
    public let streamFirstPiece: Int
    /// Byte offset in the torrent where the streamed media file begins.
    public let streamMediaByteOffset: Int64

    private var bitmap: [Bool]
    private var writeHandle: FileHandle?
    private var readHandle: FileHandle?
    /// Contiguous bytes written from the start of the streamed media file (may be unverified).
    private var streamHeadContiguousEnd: Int64 = 0

    public init(
        infoHash: String,
        pieceCount: Int,
        pieceSize: Int64,
        totalSize: Int64? = nil,
        streamFirstPiece: Int = 0,
        streamMediaByteOffset: Int64 = 0,
        storageDirectory: URL = FileManager.default.temporaryDirectory,
        existingBitmap: Data? = nil,
        recreateFile: Bool = true
    ) async throws {
        self.infoHash = infoHash
        self.pieceCount = pieceCount
        self.pieceSize = pieceSize
        self.streamFirstPiece = streamFirstPiece
        self.streamMediaByteOffset = streamMediaByteOffset
        let resolvedTotalSize = totalSize ?? Int64(pieceCount) * pieceSize
        self.totalSize = resolvedTotalSize
        self.storageURL = storageDirectory.appendingPathComponent("moviebox_\(infoHash).stream")

        if let existingBitmap, !existingBitmap.isEmpty {
            self.bitmap = Self.decodeBitmap(existingBitmap, pieceCount: pieceCount)
        } else {
            self.bitmap = Array(repeating: false, count: pieceCount)
        }

        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        let fileExists = FileManager.default.fileExists(atPath: storageURL.path)
        if recreateFile || !fileExists {
            if fileExists {
                try FileManager.default.removeItem(at: storageURL)
            }
            FileManager.default.createFile(atPath: storageURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: storageURL)
            try handle.truncate(atOffset: UInt64(resolvedTotalSize))
            try handle.close()
        }

        self.writeHandle = try FileHandle(forWritingTo: storageURL)
        self.readHandle = try FileHandle(forReadingFrom: storageURL)
    }

    public func encodedBitmap() -> Data {
        Self.encodeBitmap(bitmap)
    }

    public static func encodeBitmap(_ bitmap: [Bool]) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity((bitmap.count + 7) / 8)
        var current: UInt8 = 0
        var bitIndex = 0
        for piece in bitmap {
            if piece {
                current |= 1 << (7 - bitIndex)
            }
            bitIndex += 1
            if bitIndex == 8 {
                bytes.append(current)
                current = 0
                bitIndex = 0
            }
        }
        if bitIndex > 0 {
            bytes.append(current)
        }
        return Data(bytes)
    }

    public static func decodeBitmap(_ data: Data, pieceCount: Int) -> [Bool] {
        var result = [Bool]()
        result.reserveCapacity(pieceCount)
        for byte in data {
            for bit in 0..<8 where result.count < pieceCount {
                result.append((byte >> (7 - bit)) & 1 != 0)
            }
        }
        while result.count < pieceCount {
            result.append(false)
        }
        return result
    }

    /// Writes a block to disk immediately for progressive playback (before hash verification).
    public func writeBlock(pieceIndex: Int, blockOffset: Int64, data: Data) async throws {
        guard pieceIndex >= 0, pieceIndex < pieceCount else {
            throw PieceStoreError.invalidPieceIndex(pieceIndex)
        }

        let torrentOffset = Int64(pieceIndex) * pieceSize + blockOffset
        try writeHandle?.seek(toOffset: UInt64(torrentOffset))
        writeHandle?.write(data)

        let mediaOffset = torrentOffset - streamMediaByteOffset
        guard mediaOffset >= 0 else { return }

        let mediaEnd = mediaOffset + Int64(data.count)
        if mediaOffset <= streamHeadContiguousEnd {
            streamHeadContiguousEnd = max(streamHeadContiguousEnd, mediaEnd)
        }
    }

    public func markPieceVerified(pieceIndex: Int) {
        guard pieceIndex >= 0, pieceIndex < pieceCount else { return }
        bitmap[pieceIndex] = true
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

        let mediaOffset = offset - streamMediaByteOffset
        if mediaOffset >= 0 {
            let mediaEnd = mediaOffset + Int64(data.count)
            if mediaOffset <= streamHeadContiguousEnd {
                streamHeadContiguousEnd = max(streamHeadContiguousEnd, mediaEnd)
            }
        }
    }

    public func read(offset: Int64, length: Int) async throws -> Data {
        let clampedLength = min(length, Int(totalSize - offset))
        guard offset >= 0, clampedLength > 0, offset < totalSize else {
            throw PieceStoreError.outOfRange(offset, totalSize)
        }

        try await waitForReadable(offset: offset, length: clampedLength)

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

    public func progress() -> Double {
        guard pieceCount > 0 else { return 0 }
        let completed = bitmap.filter { $0 }.count
        return Double(completed) / Double(pieceCount)
    }

    public func contiguousPiecesFromStart() -> Int {
        var count = 0
        for index in streamFirstPiece..<bitmap.count {
            guard bitmap[index] else { break }
            count += 1
        }
        return count
    }

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

    /// Verified media bytes available from the start of the streamed file.
    public func verifiedMediaBytesFromStart() -> Int64 {
        let torrentBytes = contiguousBytesFromStreamStart()
        let pieceBase = Int64(streamFirstPiece) * pieceSize
        let prefix = max(0, streamMediaByteOffset - pieceBase)
        return max(0, torrentBytes - prefix)
    }

    /// Contiguous media bytes at the file head (includes in-flight blocks written before verify).
    public func streamHeadContiguousBytes() -> Int64 {
        streamHeadContiguousEnd
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

    private func waitForReadable(offset: Int64, length: Int) async throws {
        let end = offset + Int64(length)
        var waitCount = 0

        while true {
            try Task.checkCancellation()
            if isRangeReadable(offset: offset, end: end) {
                return
            }

            waitCount += 1
            if waitCount % 50 == 0 {
                TorrentLog.debug(
                    "[PieceStore] Waiting for readable bytes \(offset)-\(end) (head contiguous: \(streamHeadContiguousEnd))"
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func isRangeReadable(offset: Int64, end: Int64) -> Bool {
        var position = offset
        while position < end {
            let pieceIndex = Int(position / pieceSize)
            guard hasPiece(pieceIndex) else {
                return false
            }
            let pieceStart = Int64(pieceIndex) * pieceSize
            let pieceEnd = min(end, pieceStart + pieceSize(for: pieceIndex))
            position = pieceEnd
        }
        return true
    }

    /// Drops unverified bytes for a piece after hash failure so AVPlayer cannot read stale data.
    public func invalidatePiece(_ pieceIndex: Int) async throws {
        guard pieceIndex >= 0, pieceIndex < pieceCount else {
            throw PieceStoreError.invalidPieceIndex(pieceIndex)
        }
        guard let writeHandle else {
            throw PieceStoreError.ioError("Write handle unavailable")
        }

        let offset = Int64(pieceIndex) * pieceSize
        let length = Int(pieceSize(for: pieceIndex))
        try writeHandle.seek(toOffset: UInt64(offset))
        writeHandle.write(Data(repeating: 0, count: length))
        bitmap[pieceIndex] = false
        recomputeStreamHeadContiguousEnd()
    }

    private func recomputeStreamHeadContiguousEnd() {
        var end: Int64 = 0
        for index in streamFirstPiece..<pieceCount {
            guard hasPiece(index) else { break }
            let pieceStart = Int64(index) * pieceSize
            let mediaStart = pieceStart - streamMediaByteOffset
            guard mediaStart >= 0 else { continue }
            let mediaEnd = mediaStart + pieceSize(for: index)
            end = max(end, mediaEnd)
        }
        streamHeadContiguousEnd = end
    }

    private func pieceSize(for pieceIndex: Int) -> Int64 {
        if pieceIndex == pieceCount - 1 {
            return totalSize - Int64(pieceIndex) * pieceSize
        }
        return pieceSize
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
