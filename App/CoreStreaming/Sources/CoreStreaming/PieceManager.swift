import Foundation
import CryptoKit

// MARK: - Piece Manager (Streaming Priority)

public actor PieceManager {
    public let pieceCount: Int
    public let pieceLength: Int64
    public let totalSize: Int64
    public let blockSize: UInt32 = 16384

    private var pieceHashes: [Data] = []
    private var downloadedPieces: Set<UInt32> = []
    private var pendingRequests: Set<BlockRequest> = []
    private var pieceBuffers: [UInt32: Data] = [:]
    private var receivedBytes: [UInt32: Int] = [:]

    public init(pieceCount: Int, pieceLength: Int64, totalSize: Int64, piecesHash: Data) {
        self.pieceCount = pieceCount
        self.pieceLength = pieceLength
        self.totalSize = totalSize

        let cleanHash = Data(piecesHash)
        var index = 0
        while index + 20 <= cleanHash.count {
            let hash = cleanHash[index..<index + 20]
            pieceHashes.append(hash)
            index += 20
        }
    }

    public func getNextRequest() -> BlockRequest? {
        for pieceIndex in streamingOrder() {
            guard !downloadedPieces.contains(pieceIndex) else { continue }

            let pieceSize = pieceSize(for: pieceIndex)
            let blockCount = Int((pieceSize + Int64(blockSize) - 1) / Int64(blockSize))

            for blockIndex in 0..<blockCount {
                let offset = UInt32(blockIndex) * blockSize
                let length = min(blockSize, UInt32(pieceSize) - offset)
                let request = BlockRequest(pieceIndex: pieceIndex, offset: offset, length: length)

                guard !pendingRequests.contains(request) else { continue }

                pendingRequests.insert(request)
                return request
            }
        }

        return nil
    }

    public func markBlockReceived(pieceIndex: UInt32, offset: UInt32, block: Data) -> Bool {
        let request = BlockRequest(pieceIndex: pieceIndex, offset: offset, length: UInt32(block.count))
        pendingRequests.remove(request)

        let expectedSize = Int(pieceSize(for: pieceIndex))
        if pieceBuffers[pieceIndex] == nil {
            pieceBuffers[pieceIndex] = Data(count: expectedSize)
            receivedBytes[pieceIndex] = 0
        }

        guard var buffer = pieceBuffers[pieceIndex] else { return false }

        let start = Int(offset)
        let end = start + block.count
        guard start >= 0, end <= buffer.count else { return false }

        buffer.replaceSubrange(start..<end, with: block)
        pieceBuffers[pieceIndex] = buffer
        receivedBytes[pieceIndex, default: 0] += block.count

        guard receivedBytes[pieceIndex, default: 0] >= expectedSize else {
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
        Double(downloadedPieces.count) / Double(pieceCount)
    }

    public func downloadedCount() -> Int {
        downloadedPieces.count
    }

    public func getPieceData(_ pieceIndex: UInt32) -> Data? {
        pieceBuffers[pieceIndex]
    }

    private func streamingOrder() -> [UInt32] {
        var order: [UInt32] = []

        for i in 0..<pieceCount {
            if !downloadedPieces.contains(UInt32(i)) {
                order.append(UInt32(i))
            }
        }

        return order.sorted { a, b in
            let priorityA = streamingPriority(for: a)
            let priorityB = streamingPriority(for: b)
            return priorityA > priorityB
        }
    }

    private func streamingPriority(for pieceIndex: UInt32) -> Int {
        let firstPieces = min(20, pieceCount)
        if pieceIndex < firstPieces {
            return 1000 - Int(pieceIndex)
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

    private func verifyPiece(pieceIndex: UInt32, data: Data) -> Bool {
        guard Int(pieceIndex) < pieceHashes.count else { return false }

        let computedHash = Data(Insecure.SHA1.hash(data: data))
        guard computedHash == pieceHashes[Int(pieceIndex)] else {
            pieceBuffers[pieceIndex] = nil
            return false
        }

        downloadedPieces.insert(pieceIndex)
        return true
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
}
