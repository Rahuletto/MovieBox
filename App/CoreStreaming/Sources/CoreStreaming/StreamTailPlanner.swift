import Foundation

/// Piece prioritisation for streaming (first + last 1% per FINDINGS / qBittorrent-style).
public enum StreamTailPlanner {
    private static let tailPercent: Double = 0.01

    /// Last `percent` of the file by byte length (minimum two pieces).
    public static func lastPercentPieceIndices(
        target: TorrentStreamTarget,
        pieceLength: Int64,
        pieceCount: Int,
        percent: Double = 0.01
    ) -> [Int] {
        guard target.needsTailProbeForPlayback else { return [] }
        let tailBytes = max(pieceLength * 2, Int64(Double(target.byteLength) * percent))
        return tailPieceIndices(
            target: target,
            pieceLength: pieceLength,
            pieceCount: pieceCount,
            tailByteSpan: min(tailBytes, target.byteLength)
        )
    }

    /// First `percent` of the streamed file (for bootstrap alongside streamFirstPiece).
    public static func firstPercentPieceIndices(
        target: TorrentStreamTarget,
        pieceLength: Int64,
        pieceCount: Int,
        percent: Double = 0.01
    ) -> [Int] {
        let headBytes = max(pieceLength * 2, Int64(Double(target.byteLength) * percent))
        let fileStart = target.byteOffset
        let headEnd = min(fileStart + headBytes, target.byteOffset + target.byteLength)
        let first = max(target.firstPieceIndex, Int(fileStart / pieceLength))
        let last = min(target.lastPieceIndex, Int((headEnd - 1) / pieceLength), pieceCount - 1)
        guard first <= last else { return [first] }
        return Array(first...last)
    }

    /// Piece indices to prioritize: last 1% of file (moov/index region for MP4/MKV).
    public static func tailPieceIndicesForDownload(
        target: TorrentStreamTarget,
        pieceLength: Int64,
        pieceCount: Int
    ) -> [Int] {
        lastPercentPieceIndices(target: target, pieceLength: pieceLength, pieceCount: pieceCount)
    }

    public static func tailPieceIndices(
        target: TorrentStreamTarget,
        pieceLength: Int64,
        pieceCount: Int,
        tailByteSpan: Int64
    ) -> [Int] {
        guard target.needsTailProbeForPlayback else { return [] }

        let fileEnd = target.byteOffset + target.byteLength
        let tailStart = max(target.byteOffset, fileEnd - tailByteSpan)
        let first = Int(tailStart / pieceLength)
        let last = min(target.lastPieceIndex, pieceCount - 1)
        guard first <= last else { return [last] }
        return Array(first...last)
    }
}
