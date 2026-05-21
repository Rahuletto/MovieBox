import Foundation
import CryptoKit

// MARK: - Piece Manager (Streaming Priority)

public enum PieceReceiveOutcome: Sendable {
    case incomplete
    case verified
    case rejected
}

public actor PieceManager {
    public let pieceCount: Int
    public let pieceLength: Int64
    public let totalSize: Int64
    public let blockSize: UInt32 = 16384
    public let streamFirstPiece: Int
    public let streamLastPiece: Int
    public let streamTailPieces: [Int]
    public let streamMediaByteOffset: Int64
    public let streamMediaByteLength: Int64

    private var pieceHashes: [Data] = []
    private var downloadedPieces: Set<UInt32> = []
    private var pendingRequests: Set<BlockRequest> = []
    private var pieceBuffers: [UInt32: Data] = [:]
    private var receivedBlockOffsets: [UInt32: Set<UInt32>] = [:]
    /// Pieces AVPlayer recently requested via HTTP ranges (newest first).
    private var playerHotPieces: [UInt32] = []

    private static let maxHotPieces = 32
    private static let readAheadPieceCount = 3

    public init(
        pieceCount: Int,
        pieceLength: Int64,
        totalSize: Int64,
        piecesHash: Data,
        streamFirstPiece: Int = 0,
        streamLastPiece: Int? = nil,
        streamTailPieces: [Int]? = nil,
        streamMediaByteOffset: Int64 = 0,
        streamMediaByteLength: Int64? = nil
    ) {
        self.pieceCount = pieceCount
        self.pieceLength = pieceLength
        self.totalSize = totalSize
        self.streamFirstPiece = streamFirstPiece
        self.streamMediaByteOffset = streamMediaByteOffset
        self.streamMediaByteLength = streamMediaByteLength ?? max(0, totalSize - streamMediaByteOffset)
        if let streamTailPieces, !streamTailPieces.isEmpty {
            self.streamTailPieces = streamTailPieces
            self.streamLastPiece = streamTailPieces.max() ?? max(0, pieceCount - 1)
        } else {
            let last = streamLastPiece ?? max(0, pieceCount - 1)
            self.streamLastPiece = last
            self.streamTailPieces = [last]
        }

        let cleanHash = Data(piecesHash)
        var index = 0
        while index + 20 <= cleanHash.count {
            pieceHashes.append(cleanHash[index..<index + 20])
            index += 20
        }
    }

    public func setInitialDownloadedPieces(_ pieces: Set<UInt32>) {
        downloadedPieces = pieces
    }

    public func getNextRequest(peerBitfield: Data = Data()) -> BlockRequest? {
        guard let pieceIndex = earliestIncompletePiece(peerBitfield: peerBitfield) else { return nil }

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

        return nil
    }

    public func recycleRequests(_ requests: [BlockRequest]) {
        for request in requests {
            pendingRequests.remove(request)
        }
    }

    public func markBlockReceived(pieceIndex: UInt32, offset: UInt32, block: Data) -> PieceReceiveOutcome {
        pendingRequests.remove(BlockRequest(pieceIndex: pieceIndex, offset: offset, length: 0))

        let expectedSize = Int(pieceSize(for: pieceIndex))
        if pieceBuffers[pieceIndex] == nil {
            pieceBuffers[pieceIndex] = Data(count: expectedSize)
        }

        guard var buffer = pieceBuffers[pieceIndex] else { return .incomplete }

        let start = Int(offset)
        let end = start + block.count
        guard start >= 0, end <= buffer.count else { return .incomplete }

        buffer.replaceSubrange(start..<end, with: block)
        pieceBuffers[pieceIndex] = buffer

        var offsets = receivedBlockOffsets[pieceIndex] ?? []
        offsets.insert(offset)
        receivedBlockOffsets[pieceIndex] = offsets

        guard isPieceFullyReceived(pieceIndex: pieceIndex, expectedSize: expectedSize) else {
            return .incomplete
        }

        guard verifyPiece(pieceIndex: pieceIndex, data: buffer) else {
            return .rejected
        }

        return .verified
    }

    public func cancelPendingRequests() -> [BlockRequest] {
        let requests = Array(pendingRequests)
        pendingRequests.removeAll()
        return requests
    }

    public func isPieceDownloaded(_ pieceIndex: UInt32) -> Bool {
        downloadedPieces.contains(pieceIndex)
    }

    public func pieceProgress(pieceIndex: UInt32) -> Double {
        if downloadedPieces.contains(pieceIndex) {
            return 1.0
        }
        guard let offsets = receivedBlockOffsets[pieceIndex] else { return 0.0 }
        let size = Double(pieceSize(for: pieceIndex))
        guard size > 0 else { return 0.0 }
        
        let received = offsets.reduce(0.0) { sum, offset in
            let blockLen = min(Double(blockSize), size - Double(offset))
            return sum + max(0.0, blockLen)
        }
        return min(1.0, received / size)
    }

    public func progress() -> Double {
        guard pieceCount > 0 else { return 0 }
        return Double(downloadedPieces.count) / Double(pieceCount)
    }

    public func downloadedCount() -> Int {
        downloadedPieces.count
    }

    public func pendingRequestCount() -> Int {
        pendingRequests.count
    }

    public func takePieceData(_ pieceIndex: UInt32) -> Data? {
        defer { pieceBuffers.removeValue(forKey: pieceIndex) }
        return pieceBuffers[pieceIndex]
    }

    /// Called when AVPlayer requests a byte range — boosts torrent piece priority for that span.
    public func notePlayerRead(mediaOffset: Int64, length: Int) {
        let indices = pieceIndicesCovering(mediaOffset: mediaOffset, length: length)
        guard !indices.isEmpty else { return }

        var expanded = indices
        if let last = indices.last {
            for ahead in 1...Self.readAheadPieceCount {
                let next = last + UInt32(ahead)
                guard Int(next) < pieceCount else { break }
                expanded.append(next)
            }
        }

        for index in expanded.reversed() {
            playerHotPieces.removeAll { $0 == index }
            playerHotPieces.insert(index, at: 0)
        }
        if playerHotPieces.count > Self.maxHotPieces {
            playerHotPieces.removeLast(playerHotPieces.count - Self.maxHotPieces)
        }
    }

    public func playerHotPieceCount() -> Int {
        playerHotPieces.count
    }

    /// Until head + tail index pieces are verified, never fall back to middle-of-file pieces
    /// (peers without end-of-file in bitfield would otherwise pull piece 1, 2, … forever).
    private func earliestIncompletePiece(peerBitfield: Data) -> UInt32? {
        let bootstrap = buildBootstrapPriorityOrder()
        if needsIndexBootstrap() {
            return firstIncompletePiece(in: bootstrap, peerBitfield: peerBitfield)
        }

        let priority = buildFullPriorityOrder()
        return firstIncompletePiece(in: priority, peerBitfield: peerBitfield)
    }

    private func needsIndexBootstrap() -> Bool {
        guard downloadedPieces.contains(UInt32(streamFirstPiece)) else { return true }
        return streamTailPieces.contains { !downloadedPieces.contains(UInt32($0)) }
    }

    private func firstIncompletePiece(in priority: [UInt32], peerBitfield: Data) -> UInt32? {
        for index in priority {
            guard !downloadedPieces.contains(index) else { continue }
            if !peerBitfield.isEmpty, !peerHasPiece(index, in: peerBitfield) {
                continue
            }
            return index
        }
        return nil
    }

    private func buildBootstrapPriorityOrder() -> [UInt32] {
        var priority: [UInt32] = []
        func append(_ index: UInt32) {
            guard !priority.contains(index) else { return }
            priority.append(index)
        }

        for index in playerHotPieces {
            append(index)
        }
        append(UInt32(streamFirstPiece))
        for piece in streamTailPieces.reversed() {
            append(UInt32(piece))
        }
        return priority
    }

    private func buildFullPriorityOrder() -> [UInt32] {
        var priority = buildBootstrapPriorityOrder()
        func append(_ index: UInt32) {
            guard !priority.contains(index) else { return }
            priority.append(index)
        }

        for i in streamFirstPiece..<pieceCount {
            append(UInt32(i))
        }
        return priority
    }

    private func pieceIndicesCovering(mediaOffset: Int64, length: Int) -> [UInt32] {
        guard length > 0, mediaOffset >= 0 else { return [] }
        let span = min(Int64(length), streamMediaByteLength - mediaOffset)
        guard span > 0 else { return [] }

        let torrentStart = streamMediaByteOffset + mediaOffset
        let torrentEnd = torrentStart + span - 1
        let first = max(0, Int(torrentStart / pieceLength))
        let last = min(pieceCount - 1, Int(torrentEnd / pieceLength))
        guard first <= last else { return [] }
        return (first...last).map { UInt32($0) }
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
        pieceBuffers.removeValue(forKey: pieceIndex)
        receivedBlockOffsets.removeValue(forKey: pieceIndex)
        trimPieceBuffers(keeping: pieceIndex)
        return true
    }

    private func trimPieceBuffers(keeping current: UInt32) {
        let maxBuffers = 64
        guard pieceBuffers.count > maxBuffers else { return }

        let tailSet = Set(streamTailPieces.map { UInt32($0) })
        let hotSet = Set(playerHotPieces)

        let candidates = pieceBuffers.keys.filter { key in
            key != current && !tailSet.contains(key) && !hotSet.contains(key)
        }

        for key in candidates {
            resetPiece(key)
            if pieceBuffers.count <= maxBuffers { break }
        }
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
