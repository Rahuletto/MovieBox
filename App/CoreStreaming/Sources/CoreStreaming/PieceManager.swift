import Foundation
import CryptoKit

// MARK: - Piece Manager (Streaming Priority)

public actor PieceManager {
    public let pieceCount: Int
    public let pieceLength: Int64
    public let totalSize: Int64
    public let blockSize: UInt32 = 16384
    public let streamFirstPiece: Int

    private var pieceHashes: [Data] = []
    private var downloadedPieces: Set<UInt32> = []
    private var pendingRequests: Set<BlockRequest> = []
    private var pieceBuffers: [UInt32: Data] = [:]
    /// Tracks which block offsets within a piece have been written (handles duplicate deliveries).
    private var receivedBlockOffsets: [UInt32: Set<UInt32>] = [:]

    public init(
        pieceCount: Int,
        pieceLength: Int64,
        totalSize: Int64,
        piecesHash: Data,
        streamFirstPiece: Int = 0
    ) {
        self.pieceCount = pieceCount
        self.pieceLength = pieceLength
        self.totalSize = totalSize
        self.streamFirstPiece = streamFirstPiece

        let cleanHash = Data(piecesHash)
        var index = 0
        while index + 20 <= cleanHash.count {
            pieceHashes.append(cleanHash[index..<index + 20])
            index += 20
        }
    }

    public func getNextRequest(peerBitfield: Data = Data()) -> BlockRequest? {
        for pieceIndex in streamingOrder() {
            guard !downloadedPieces.contains(pieceIndex) else { continue }

            if !peerBitfield.isEmpty, !peerHasPiece(pieceIndex, in: peerBitfield) {
                continue
            }

            let pieceSize = pieceSize(for: pieceIndex)
            let blockCount = Int((pieceSize + Int64(blockSize) - 1) / Int64(blockSize))

            for blockIndex in 0..<blockCount {
                let offset = UInt32(blockIndex) * blockSize
                if receivedBlockOffsets[pieceIndex]?.contains(offset) == true {
                    continue
                }

                let length = min(blockSize, UInt32(pieceSize) - offset)
                let request = BlockRequest(pieceIndex: pieceIndex, offset: offset, length: length)

                guard !pendingRequests.contains(request) else { continue }

                pendingRequests.insert(request)
                return request
            }
        }

        return nil
    }

    public func recycleRequests(_ requests: [BlockRequest]) {
        for request in requests {
            pendingRequests.remove(request)
        }
    }

    public func markBlockReceived(pieceIndex: UInt32, offset: UInt32, block: Data) -> Bool {
        pendingRequests.remove(BlockRequest(pieceIndex: pieceIndex, offset: offset, length: 0))

        let expectedSize = Int(pieceSize(for: pieceIndex))
        if pieceBuffers[pieceIndex] == nil {
            pieceBuffers[pieceIndex] = Data(count: expectedSize)
        }

        guard var buffer = pieceBuffers[pieceIndex] else { return false }

        let start = Int(offset)
        let end = start + block.count
        guard start >= 0, end <= buffer.count else { return false }

        buffer.replaceSubrange(start..<end, with: block)
        pieceBuffers[pieceIndex] = buffer

        var offsets = receivedBlockOffsets[pieceIndex] ?? []
        offsets.insert(offset)
        receivedBlockOffsets[pieceIndex] = offsets

        guard isPieceFullyReceived(pieceIndex: pieceIndex, expectedSize: expectedSize) else {
            return false
        }

        return verifyPiece(pieceIndex: pieceIndex, data: buffer)
    }

    public func cancelPendingRequests() -> [BlockRequest] {
        let requests = Array(pendingRequests)
        pendingRequests.removeAll()
        return requests
    }

    public func isPieceDownloaded(_ pieceIndex: UInt32) -> Bool {
        downloadedPieces.contains(pieceIndex)
    }

    public func progress() -> Double {
        guard pieceCount > 0 else { return 0 }
        return Double(downloadedPieces.count) / Double(pieceCount)
    }

    public func downloadedCount() -> Int {
        downloadedPieces.count
    }

    public func getPieceData(_ pieceIndex: UInt32) -> Data? {
        pieceBuffers[pieceIndex]
    }

    private func isPieceFullyReceived(pieceIndex: UInt32, expectedSize: Int) -> Bool {
        let blockCount = Int((Int64(expectedSize) + Int64(blockSize) - 1) / Int64(blockSize))
        guard let offsets = receivedBlockOffsets[pieceIndex], offsets.count >= blockCount else {
            return false
        }
        for blockIndex in 0..<blockCount {
            let offset = UInt32(blockIndex) * blockSize
            if !offsets.contains(offset) { return false }
        }
        return true
    }

    private func resetPiece(_ pieceIndex: UInt32) {
        pieceBuffers[pieceIndex] = nil
        receivedBlockOffsets[pieceIndex] = nil
        pendingRequests = pendingRequests.filter { $0.pieceIndex != pieceIndex }
    }

    private func streamingOrder() -> [UInt32] {
        var order: [UInt32] = []
        for i in 0..<pieceCount {
            let index = UInt32(i)
            if !downloadedPieces.contains(index) {
                order.append(index)
            }
        }

        return order.sorted { streamingPriority(for: $0) > streamingPriority(for: $1) }
    }

    private func streamingPriority(for pieceIndex: UInt32) -> Int {
        let streamStart = UInt32(streamFirstPiece)
        let headWindow = 24

        if pieceIndex >= streamStart && pieceIndex < streamStart + UInt32(headWindow) {
            return 2000 - Int(pieceIndex - streamStart)
        }

        // MP4/MOV often store the `moov` atom in the last ~1% of the file.
        if pieceIndex == UInt32(pieceCount - 1) {
            return 800
        }
        if pieceCount > 2, pieceIndex == UInt32(pieceCount - 2) {
            return 400
        }

        return 0
    }

    private func pieceSize(for pieceIndex: UInt32) -> Int64 {
        let index = Int(pieceIndex)
        if index == pieceCount - 1 {
            return totalSize - (Int64(index) * pieceLength)
        }
        return pieceLength
    }

    private func peerHasPiece(_ pieceIndex: UInt32, in bitfield: Data) -> Bool {
        let byteIndex = Int(pieceIndex / 8)
        let bitIndex = Int(pieceIndex % 8)
        guard byteIndex < bitfield.count else { return false }
        return (bitfield[byteIndex] & (1 << (7 - bitIndex))) != 0
    }

    private func verifyPiece(pieceIndex: UInt32, data: Data) -> Bool {
        guard Int(pieceIndex) < pieceHashes.count else { return false }

        let computedHash = Data(Insecure.SHA1.hash(data: data))
        guard computedHash == pieceHashes[Int(pieceIndex)] else {
            TorrentLog.debug("[PieceManager] Hash mismatch on piece \(pieceIndex), retrying")
            resetPiece(pieceIndex)
            return false
        }

        downloadedPieces.insert(pieceIndex)
        receivedBlockOffsets.removeValue(forKey: pieceIndex)
        return true
    }

    public func takePieceData(_ pieceIndex: UInt32) -> Data? {
        defer { pieceBuffers.removeValue(forKey: pieceIndex) }
        return pieceBuffers[pieceIndex]
    }
}

public struct BlockRequest: Hashable, Sendable {
    public let pieceIndex: UInt32
    public let offset: UInt32
    public let length: UInt32

    public init(pieceIndex: UInt32, offset: UInt32, length: UInt32) {
        self.pieceIndex = pieceIndex
        self.offset = offset
        self.length = length
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(pieceIndex)
        hasher.combine(offset)
    }

    public static func == (lhs: BlockRequest, rhs: BlockRequest) -> Bool {
        lhs.pieceIndex == rhs.pieceIndex && lhs.offset == rhs.offset
    }
}
