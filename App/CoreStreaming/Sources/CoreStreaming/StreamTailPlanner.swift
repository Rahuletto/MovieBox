import Foundation

/// Decides which torrent pieces must be verified before MP4/MKV streaming can start.
public enum StreamTailPlanner {
    /// Initial tail fetch before probing for `moov` (expanded until index is complete).
    public static let defaultTailByteSpan: Int64 = 8 * 1024 * 1024
    /// Upper bound when growing the tail window for large moov atoms.
    public static let maxTailByteSpan: Int64 = 64 * 1024 * 1024

    public enum MoovTailProbeResult: Equatable {
        case complete
        case incomplete
        case notFound
    }

    public static func tailByteSpan(byteLength: Int64, pieceLength: Int64) -> Int64 {
        let scaled: Int64
        if byteLength > 2_500_000_000 {
            scaled = 32 * 1024 * 1024
        } else if byteLength > 1_000_000_000 {
            scaled = 16 * 1024 * 1024
        } else {
            scaled = defaultTailByteSpan
        }
        return min(max(scaled, pieceLength * 2), byteLength, maxTailByteSpan)
    }

    /// Piece indices to prioritize for download (uses max tail span so expanded probes stay covered).
    public static func tailPieceIndicesForDownload(
        target: TorrentStreamTarget,
        pieceLength: Int64,
        pieceCount: Int
    ) -> [Int] {
        tailPieceIndices(
            target: target,
            pieceLength: pieceLength,
            pieceCount: pieceCount,
            tailByteSpan: min(target.byteLength, maxTailByteSpan)
        )
    }

    public static func tailPieceIndices(
        target: TorrentStreamTarget,
        pieceLength: Int64,
        pieceCount: Int,
        tailByteSpan: Int64? = nil
    ) -> [Int] {
        guard target.needsTailProbeForPlayback else { return [] }

        let tailBytes = tailByteSpan ?? Self.tailByteSpan(byteLength: target.byteLength, pieceLength: pieceLength)
        let fileEnd = target.byteOffset + target.byteLength
        let tailStart = max(target.byteOffset, fileEnd - tailBytes)
        let first = Int(tailStart / pieceLength)
        let last = min(target.lastPieceIndex, pieceCount - 1)
        guard first <= last else { return [last] }
        return Array(first...last)
    }

    /// Whether a verified tail buffer contains a full `moov` box (not a truncated index).
    public static func moovTailProbe(in tailData: Data, endsAtFileEOF: Bool) -> MoovTailProbeResult {
        guard tailData.count >= 16 else { return .notFound }

        var sawIncomplete = false
        var i = 0
        while i + 8 <= tailData.count {
            guard let box = readBox(at: i, in: tailData) else {
                i += 1
                continue
            }
            if box.type == "moov" {
                if box.end <= tailData.count {
                    if endsAtFileEOF, box.end == tailData.count {
                        return .complete
                    }
                    return .complete
                }
                sawIncomplete = true
            }
            i = box.end
        }

        for offset in 0..<(tailData.count - 8) {
            guard tailData[offset + 4..<offset + 8] == Data("moov".utf8) else { continue }
            guard let box = readBox(at: offset, in: tailData) else { continue }
            guard box.type == "moov" else { continue }
            if box.end <= tailData.count {
                if endsAtFileEOF, box.end == tailData.count {
                    return .complete
                }
                return .complete
            }
            sawIncomplete = true
        }

        return sawIncomplete ? .incomplete : .notFound
    }

    /// True only for progressive/fast-start MP4 where `moov` appears before the first `mdat`.
    /// Does not use byte substring search (avoids false positives inside `mdat` payload).
    public static func isFastStartMP4(in data: Data) -> Bool {
        var offset = 0
        while offset + 8 <= data.count {
            guard let box = readBox(at: offset, in: data) else { break }
            switch box.type {
            case "moov":
                return true
            case "mdat":
                return false
            case "ftyp", "styp", "free", "skip", "wide", "uuid":
                offset = box.end
            default:
                offset = box.end
            }
        }
        return false
    }

    private struct BoxHeader {
        let size: Int
        let type: String
        let end: Int
    }

    private static func readBox(at offset: Int, in data: Data) -> BoxHeader? {
        guard offset + 8 <= data.count else { return nil }
        let size32 = Int(data.readUInt32BE(at: offset))
        let type = String(data: data[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
        guard size32 >= 8 else { return nil }

        var size = size32
        var header = 8
        if size32 == 1, offset + 16 <= data.count {
            let large = data.readUInt64BE(at: offset + 8)
            guard large >= 16, large <= Int64(data.count - offset) else { return nil }
            size = Int(large)
            header = 16
        }

        guard size >= header, offset + size <= data.count else { return nil }
        return BoxHeader(size: size, type: type, end: offset + size)
    }
}

private extension Data {
    func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }

    func readUInt64BE(at offset: Int) -> Int64 {
        guard offset + 8 <= count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(self[offset + i])
        }
        return Int64(value)
    }
}
