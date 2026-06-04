import CoreStreaming
import XCTest

final class PieceManagerTests: XCTestCase {
    func testAdvancePlaybackAnchorPastStreamEndDoesNotTrap() async {
        let pieceCount = 20
        let pieceLength: Int64 = 16_384
        let totalSize = pieceLength * Int64(pieceCount)
        let piecesHash = Data(repeating: 0xAB, count: 20 * pieceCount)
        let manager = PieceManager(
            pieceCount: pieceCount,
            pieceLength: pieceLength,
            totalSize: totalSize,
            piecesHash: piecesHash,
            streamFirstPiece: 0,
            streamLastPiece: 5
        )

        await manager.notePlayerRead(mediaOffset: 0, length: 16_384)
        await manager.confirmPiecesVerifiedOnDisk(Array(0...5))

        let anchor = await manager.playbackAnchorPieceIndex()
        XCTAssertNil(anchor)
    }

    func testSeekNearStreamEndDoesNotTrapOnCriticalRange() async {
        let pieceCount = 50
        let pieceLength: Int64 = 16_384
        let totalSize = pieceLength * Int64(pieceCount)
        let piecesHash = Data(repeating: 0xCD, count: 20 * pieceCount)
        let streamLast = 10
        let manager = PieceManager(
            pieceCount: pieceCount,
            pieceLength: pieceLength,
            totalSize: totalSize,
            piecesHash: piecesHash,
            streamFirstPiece: 0,
            streamLastPiece: streamLast
        )

        let seekOffset = Int64(streamLast) * pieceLength
        await manager.markUserSeekPlayback(atMediaOffset: seekOffset, length: 16_384)
        _ = await manager.getNextRequest()

        await manager.confirmPiecesVerifiedOnDisk([streamLast])
        let anchor = await manager.playbackAnchorPieceIndex()
        XCTAssertNil(anchor)
    }
}
