import Foundation

/// Decides which torrent pieces must be verified before MP4/MKV streaming can start.
public enum StreamTailPlanner {
    /// Initial tail fetch before probing for `moov` (expanded until index is complete).
    public static let defaultTailByteSpan: Int64 = 8 * 1024 * 1024
    /// Upper bound when growing the tail window for large moov atoms.
    public static let maxTailByteSpan: Int64 = 64 * 1024 * 1024

    public enum MoovTailProbeResult: Equatable, Sendable {
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
        guard tailData.count >= 8 else { return .notFound }

        // Scan backwards to find the last (real) moov box
        var offset = tailData.count - 8
        while offset >= 0 {
            if tailData[offset + 4] == 0x6D /* m */,
               tailData[offset + 5] == 0x6F /* o */,
               tailData[offset + 6] == 0x6F /* o */,
               tailData[offset + 7] == 0x76 /* v */ {
                guard let header = mp4BoxHeader(at: offset, in: tailData, endsAtFileEOF: endsAtFileEOF) else {
                    return .incomplete
                }
                if header.endOffset <= tailData.count {
                    return .complete
                } else {
                    return .incomplete
                }
            }
            offset -= 1
        }

        return .notFound
    }

    /// Parsed ISO-BMFF box header. Sizes stay in `UInt64` so 64-bit `size==1` boxes never trap.
    private struct MP4BoxHeader {
        let type: String
        let size: UInt64
        let headerSize: Int
        let startOffset: Int

        var endOffset: Int {
            guard size <= UInt64(Int.max - startOffset) else { return Int.max }
            return startOffset + Int(size)
        }

        func nextOffset(in bufferCount: Int) -> Int? {
            guard size >= UInt64(headerSize), endOffset <= bufferCount, endOffset > startOffset else { return nil }
            return endOffset
        }
    }

    private static func mp4BoxHeader(at offset: Int, in data: Data, endsAtFileEOF: Bool) -> MP4BoxHeader? {
        guard offset + 8 <= data.count else { return nil }
        let size32 = data.readUInt32BE(at: offset)
        let type = String(data: data[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""

        let size: UInt64
        let headerSize: Int
        if size32 == 1 {
            guard offset + 16 <= data.count else { return nil }
            size = data.readUInt64BE(at: offset + 8)
            guard size >= 16 else { return nil }
            headerSize = 16
        } else if size32 == 0 {
            guard endsAtFileEOF else { return nil }
            size = UInt64(data.count - offset)
            headerSize = 8
        } else {
            size = UInt64(size32)
            headerSize = 8
            guard size >= 8 else { return nil }
        }

        return MP4BoxHeader(type: type, size: size, headerSize: headerSize, startOffset: offset)
    }

    // MARK: - MKV / WebM seek-index probe

    public enum MKVSeekTableProbeResult: Equatable, Sendable {
        /// Cues element found and fully contained in buffer.
        case complete
        /// Cues element found but extends past buffer boundary.
        case incomplete
        /// No Cues element in buffer at all.
        case notFound
    }

    /// Detects whether the MKV `Cues` element (EBML id 0x1C53BB6B) is fully present
    /// in the supplied buffer. Without `Cues`, AVFoundation cannot open an MKV stream.
    public static func mkvSeekTableProbe(in data: Data) -> MKVSeekTableProbeResult {
        // Cues element ID: 0x1C53BB6B (4 bytes, EBML class A)
        let cuesID: [UInt8] = [0x1C, 0x53, 0xBB, 0x6B]
        guard let cuesRange = data.range(of: Data(cuesID)) else {
            return .notFound
        }

        let sizeFieldStart = cuesRange.upperBound
        guard sizeFieldStart < data.endIndex else { return .incomplete }

        guard let (cuesSize, sizeBytes) = parseEBMLSize(data: data, offset: sizeFieldStart) else {
            return .incomplete
        }

        // Cues element with unknown-size encoding is treated as extending to EOF — incomplete.
        guard cuesSize != UInt64.max else { return .incomplete }

        let payloadStart = sizeFieldStart + sizeBytes
        guard cuesSize <= UInt64(Int.max - payloadStart) else { return .incomplete }
        let cuesEnd = payloadStart + Int(cuesSize)
        return cuesEnd <= data.endIndex ? .complete : .incomplete
    }

    public struct MKVCuesAnalysis: Equatable, Sendable {
        /// Cluster positions relative to the Segment element body (CueClusterPosition values).
        public let firstClusterOffsets: [Int64]
        /// Absolute byte offset of the Segment element body in the torrent file.
        public let segmentBodyOffset: Int64
    }

    /// Absolute offset in the torrent file where the Segment element body begins.
    public static func segmentBodyOffset(in headData: Data, fileOffset: Int64) -> Int64? {
        let segmentID: [UInt8] = [0x18, 0x53, 0x80, 0x67]
        guard let segRange = headData.range(of: Data(segmentID)) else { return nil }
        let sizeFieldStart = segRange.upperBound
        guard let (_, sizeBytes) = parseEBMLSize(data: headData, offset: sizeFieldStart) else { return nil }
        return fileOffset + Int64(sizeFieldStart + sizeBytes)
    }

    /// Parses CueClusterPosition entries from a verified Cues block in the tail buffer.
    public static func analyzeMKVCues(in tailData: Data, segmentBodyOffset: Int64) -> MKVCuesAnalysis? {
        let cuesID: [UInt8] = [0x1C, 0x53, 0xBB, 0x6B]
        guard let cuesRange = tailData.range(of: Data(cuesID)) else { return nil }
        let cuesSizeStart = cuesRange.upperBound
        guard let (cuesSize, cuesSizeLen) = parseEBMLSize(data: tailData, offset: cuesSizeStart) else { return nil }
        guard cuesSize != UInt64.max else { return nil }

        let cuesBodyStart = cuesSizeStart + cuesSizeLen
        guard cuesSize <= UInt64(tailData.count - cuesBodyStart) else { return nil }
        let cuesBodyEnd = cuesBodyStart + Int(cuesSize)
        guard cuesBodyEnd <= tailData.count else { return nil }

        var offsets: [Int64] = []
        var pos = cuesBodyStart
        while pos < cuesBodyEnd, offsets.count < 8 {
            guard pos < tailData.count, tailData[pos] == 0xBB else {
                pos += 1
                continue
            }
            pos += 1
            guard let (cpSize, cpSizeLen) = parseEBMLSize(data: tailData, offset: pos) else { break }
            let cpBodyStart = pos + cpSizeLen
            guard cpSize <= UInt64(cuesBodyEnd - cpBodyStart) else { break }
            let cpBodyEnd = cpBodyStart + Int(cpSize)
            guard cpBodyEnd <= cuesBodyEnd else { break }
            pos = cpBodyEnd

            var inner = cpBodyStart
            while inner < cpBodyEnd {
                guard inner < tailData.count else { break }
                if tailData[inner] == 0xF1 {
                    inner += 1
                    guard let (valSize, valSizeLen) = parseEBMLSize(data: tailData, offset: inner) else { break }
                    let valStart = inner + valSizeLen
                    guard valSize <= UInt64(cpBodyEnd - valStart) else { break }
                    let valEnd = valStart + Int(valSize)
                    guard valEnd <= cpBodyEnd else { break }
                    var clusterOffset: Int64 = 0
                    for byteIndex in valStart..<valEnd {
                        clusterOffset = (clusterOffset << 8) | Int64(tailData[byteIndex])
                    }
                    offsets.append(clusterOffset)
                    break
                }
                inner += 1
            }
        }

        guard !offsets.isEmpty else { return nil }
        return MKVCuesAnalysis(firstClusterOffsets: offsets, segmentBodyOffset: segmentBodyOffset)
    }

    /// Parses an EBML variable-length unsigned integer.
    /// Returns the decoded value and the number of bytes consumed.
    /// `UInt64.max` indicates the special "unknown size" sentinel (all value bits set to 1).
    public static func parseEBMLSize(data: Data, offset: Int) -> (size: UInt64, headerBytes: Int)? {
        guard offset < data.endIndex else { return nil }
        let firstByte = data[offset]
        guard firstByte != 0 else { return nil }

        var width = 1
        var marker: UInt8 = 0x80
        while width <= 8, firstByte & marker == 0 {
            marker >>= 1
            width += 1
        }
        guard width <= 8, firstByte & marker != 0 else { return nil }
        guard offset + width <= data.endIndex else { return nil }

        // First-byte value bits: for 8-octet VINT the marker is bit 0, so shift right;
        // for shorter VINTs strip the single length marker bit via (marker - 1).
        var size: UInt64
        if width == 8 {
            size = UInt64(firstByte >> 1)
        } else {
            size = UInt64(firstByte & (marker &- 1))
        }
        for i in 1..<width {
            size = (size << 8) | UInt64(data[offset + i])
        }

        // Unknown-size sentinel: all value bits are 1 (2^(7*width) - 1).
        let unknownSizeValue = (UInt64(1) << UInt64(7 * width)) - 1
        if size == unknownSizeValue {
            return (UInt64.max, width)
        }

        return (size, width)
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
        guard let header = mp4BoxHeader(at: offset, in: data, endsAtFileEOF: false) else { return nil }
        guard let next = header.nextOffset(in: data.count) else { return nil }
        return BoxHeader(size: next - offset, type: header.type, end: next)
    }
}

private extension Data {
    func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(self[offset + i])
        }
        return value
    }
}
