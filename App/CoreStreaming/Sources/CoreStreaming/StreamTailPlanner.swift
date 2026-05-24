import Foundation

/// Piece prioritisation for streaming (first + last 1% per qBittorrent-style).
public enum StreamTailPlanner {
    private static let tailPercent: Double = 0.01

    private static func tailByteSpan(
        target: TorrentStreamTarget,
        pieceLength: Int64,
        percent: Double
    ) -> Int64 {
        let ext = (target.file.relativePath as NSString).pathExtension.lowercased()
        let isMatroska = ext == "mkv" || ext == "webm" || target.contentType.contains("matroska")
        if isMatroska {
            // MKV Cues often span the last 8–16 MB (Interstellar/Off Campus -11828 at play).
            return min(target.byteLength, max(16 * 1024 * 1024, Int64(Double(target.byteLength) * 0.02)))
        }
        return max(pieceLength * 2, Int64(Double(target.byteLength) * percent))
    }

    /// Last `percent` of the file by byte length (minimum two pieces).
    public static func lastPercentPieceIndices(
        target: TorrentStreamTarget,
        pieceLength: Int64,
        pieceCount: Int,
        percent: Double = 0.01
    ) -> [Int] {
        guard target.needsTailProbeForPlayback else { return [] }
        let tailBytes = tailByteSpan(target: target, pieceLength: pieceLength, percent: percent)
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

    /// qBittorrent-style bootstrap set: first 1% + last 1% of the streamed file.
    public static func bootstrapPieceIndices(
        target: TorrentStreamTarget,
        pieceLength: Int64,
        pieceCount: Int
    ) -> [Int] {
        let first = firstPercentPieceIndices(target: target, pieceLength: pieceLength, pieceCount: pieceCount)
        let last = lastPercentPieceIndices(target: target, pieceLength: pieceLength, pieceCount: pieceCount)
        return Array(Set(first + last)).sorted()
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
