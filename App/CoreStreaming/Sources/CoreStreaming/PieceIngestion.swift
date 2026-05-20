import Foundation

/// Applies an incoming block to disk and piece assembly (shared by engine + tests).
enum PieceIngestion {
    static func apply(
        pieceStore: PieceStore,
        pieceManager: PieceManager,
        pieceIndex: UInt32,
        offset: UInt32,
        block: Data
    ) async -> Bool {
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
