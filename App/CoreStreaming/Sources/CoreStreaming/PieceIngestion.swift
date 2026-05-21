import Foundation

/// Applies an incoming block to disk and piece assembly (shared by engine + tests).
enum PieceIngestion {
    /// Maximum allowed block size per the BitTorrent wire protocol (2^14 = 16 384 bytes).
    /// We allow 4× this to tolerate non-standard clients, but reject anything bigger.
    static let maxBlockBytes = 4 * 16_384 // 65 536 bytes

    static func apply(
        pieceStore: PieceStore,
        pieceManager: PieceManager,
        pieceIndex: UInt32,
        offset: UInt32,
        block: Data
    ) async -> Bool {
        // SECURITY: Reject oversized or out-of-bounds blocks before touching disk.
        // A malicious peer could send a block whose offset + size exceeds the piece
        // boundary, overwriting adjacent pieces or even outside the torrent file.
        guard block.count > 0, block.count <= maxBlockBytes else {
            TorrentLog.warn("[PieceIngestion] Rejecting block p\(pieceIndex)@\(offset): size \(block.count) out of range")
            return false
        }

        let pieceLength = await pieceStore.pieceSize
        let blockEnd = Int64(offset) + Int64(block.count)
        guard blockEnd <= pieceLength else {
            TorrentLog.warn("[PieceIngestion] Rejecting block p\(pieceIndex)@\(offset)+\(block.count): exceeds piece length \(pieceLength)")
            return false
        }

        do {
            try await pieceStore.writeBlock(
                pieceIndex: Int(pieceIndex),
                blockOffset: Int64(offset),
                data: block
            )
        } catch {
            TorrentLog.warn("[PieceIngestion] Block write failed p\(pieceIndex) @\(offset): \(error)")
        }

        let outcome = await pieceManager.markBlockReceived(
            pieceIndex: pieceIndex,
            offset: offset,
            block: block
        )

        switch outcome {
        case .verified:
            _ = await pieceManager.takePieceData(pieceIndex)
            await pieceStore.markPieceVerified(pieceIndex: Int(pieceIndex))
            return true
        case .rejected:
            try? await pieceStore.invalidatePiece(Int(pieceIndex))
            return false
        case .incomplete:
            return false
        }
    }
}
