import Foundation

/// Matroska index regions to prioritize (Cues element and SeekHead targets).
public enum MKVSeekBootstrap {
    private static let cuesElementID: [UInt8] = [0x1C, 0x53, 0xBB, 0x6B]
    private static let segmentElementID: [UInt8] = [0x18, 0x53, 0x80, 0x67]
    private static let cuePointElementID: [UInt8] = [0xBB]
    private static let cueTimeElementID: [UInt8] = [0xB3]
    private static let cueClusterPositionElementID: [UInt8] = [0xF1]

    /// Media-relative byte offset for a timeline position using CueTime/CueClusterPosition when present.
    static func mediaOffsetForPlaybackTime(
        seconds: Double,
        durationSeconds: Double,
        head: Data,
        tail: Data,
        tailMediaOffset: Int64,
        mediaByteLength: Int64
    ) -> Int64? {
        guard seconds.isFinite, seconds >= 0, mediaByteLength > 0 else { return nil }
        guard let segmentContentStart = segmentContentStartOffset(in: head) else { return nil }

        let timecodeScale = parseTimecodeScale(head: head) ?? 1_000_000
        let targetTime = UInt64(seconds * 1_000_000_000 / Double(timecodeScale))
        var cues: [(time: UInt64, mediaOffset: UInt64)] = []
        cues.append(contentsOf: parseCuePoints(in: head, dataMediaOffset: 0, segmentContentStart: segmentContentStart))
        cues.append(contentsOf: parseCuePoints(in: tail, dataMediaOffset: UInt64(max(0, tailMediaOffset)), segmentContentStart: segmentContentStart))
        guard !cues.isEmpty else { return nil }

        cues.sort { $0.time < $1.time }
        guard let match = cues.last(where: { $0.time <= targetTime }) ?? cues.first else { return nil }
        let offset = Int64(match.mediaOffset)
        let clamped = max(0, min(mediaByteLength - 1, offset))

        let fraction = durationSeconds > 0 ? seconds / durationSeconds : 0
        let linear = Int64(Double(mediaByteLength) * max(0, min(1, fraction)))
        let slack = Int64(Double(mediaByteLength) * 0.22)
        let minOK = max(0, linear - slack)
        let maxOK = min(mediaByteLength - 1, linear + slack)
        let eofGuardStart = max(0, mediaByteLength - max(16 * 1024 * 1024, mediaByteLength / 100))
        guard clamped < eofGuardStart || fraction > 0.95 else { return nil }
        guard clamped >= minOK, clamped <= maxOK else { return nil }
        return clamped
    }

    /// Media-relative byte offsets to boost once head/tail bytes are readable.
    static func mediaOffsetsToBoost(
        head: Data,
        tail: Data,
        tailMediaOffset: Int64
    ) -> [Int64] {
        var offsets: [Int64] = []
        for position in findAll(elementID: cuesElementID, in: head) {
            offsets.append(Int64(position))
        }
        for position in findAll(elementID: cuesElementID, in: tail) {
            offsets.append(tailMediaOffset + Int64(position))
        }
        offsets.append(contentsOf: seekHeadCuePositions(in: head))
        var unique: [Int64] = []
        for offset in offsets where offset >= 0 {
            if !unique.contains(offset) { unique.append(offset) }
        }
        return unique
    }

    private static func segmentContentStartOffset(in head: Data) -> UInt64? {
        guard let segmentOffset = findAll(elementID: segmentElementID, in: head).first else { return nil }
        let bytes = [UInt8](head)
        var offset = segmentOffset + segmentElementID.count
        guard offset < bytes.count,
              let (_, headerLen) = readEBMLSize(bytes: bytes, at: offset) else { return nil }
        return UInt64(segmentOffset + segmentElementID.count + headerLen)
    }

    private static func parseCuePoints(in data: Data, dataMediaOffset _: UInt64, segmentContentStart: UInt64) -> [(time: UInt64, mediaOffset: UInt64)] {
        guard data.count >= 32 else { return [] }
        var results: [(UInt64, UInt64)] = []
        for cuesStart in findAll(elementID: cuesElementID, in: data) {
            guard let cuesRange = elementDataRange(in: data, elementStart: cuesStart, elementID: cuesElementID) else {
                continue
            }
            var offset = cuesRange.lowerBound
            while offset < cuesRange.upperBound {
                guard let cuePointStart = findElementStart(
                    id: cuePointElementID,
                    in: data,
                    searchRange: offset..<cuesRange.upperBound
                ) else { break }
                guard let cuePointRange = elementDataRange(
                    in: data,
                    elementStart: cuePointStart,
                    elementID: cuePointElementID
                ) else { break }

                if let time = readChildUInt(
                    id: cueTimeElementID,
                    in: data,
                    parentRange: cuePointRange
                ),
                    let cluster = readChildUInt(
                        id: cueClusterPositionElementID,
                        in: data,
                        parentRange: cuePointRange
                    ) {
                    // CueClusterPosition is relative to the Matroska Segment, regardless of
                    // whether the Cues element itself was parsed from the head or tail buffer.
                    let fileOffset = segmentContentStart + cluster
                    results.append((time, fileOffset))
                }
                offset = cuePointRange.upperBound
            }
        }
        return results
    }

    private static func parseTimecodeScale(head: Data) -> UInt64? {
        let id: [UInt8] = [0x2A, 0xD7, 0xB1]
        guard let range = findElementData(id: id, in: head) else { return nil }
        return readEBMLUInt(data: head, range: range)
    }

    private static func findElementStart(id: [UInt8], in data: Data, searchRange: Range<Int>) -> Int? {
        guard searchRange.lowerBound >= 0, searchRange.upperBound <= data.count else { return nil }
        let m = id.count
        return data.withUnsafeBytes { rawBuffer -> Int? in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var i = searchRange.lowerBound
            while i + m <= searchRange.upperBound {
                var match = true
                for j in 0..<m {
                    if baseAddress[i + j] != id[j] {
                        match = false
                        break
                    }
                }
                if match { return i }
                i += 1
            }
            return nil
        }
    }

    private static func elementDataRange(in data: Data, elementStart: Int, elementID: [UInt8]) -> Range<Int>? {
        let bytes = [UInt8](data)
        var offset = elementStart + elementID.count
        guard offset < bytes.count,
              let (size, headerLen) = readEBMLSize(bytes: bytes, at: offset) else { return nil }
        offset += headerLen
        let end = offset + Int(size)
        guard end <= bytes.count else { return nil }
        return offset..<end
    }

    private static func readChildUInt(id: [UInt8], in data: Data, parentRange: Range<Int>) -> UInt64? {
        guard let childStart = findElementStart(id: id, in: data, searchRange: parentRange) else { return nil }
        let bytes = [UInt8](data)
        var offset = childStart + id.count
        guard offset < bytes.count,
              let (size, headerLen) = readEBMLSize(bytes: bytes, at: offset) else { return nil }
        offset += headerLen
        let end = offset + Int(size)
        guard end <= bytes.count, size > 0, size <= 8 else { return nil }
        var value: UInt64 = 0
        for i in offset..<end {
            value = (value << 8) | UInt64(bytes[i])
        }
        return value
    }

    private static func findElementData(id: [UInt8], in data: Data) -> Range<Int>? {
        guard let start = findAll(elementID: id, in: data).first else { return nil }
        return elementDataRange(in: data, elementStart: start, elementID: id)
    }

    private static func readEBMLUInt(data: Data, range: Range<Int>) -> UInt64? {
        let bytes = [UInt8](data[range])
        guard !bytes.isEmpty, bytes.count <= 8 else { return nil }
        var value: UInt64 = 0
        for byte in bytes {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    private static func readEBMLSize(bytes: [UInt8], at offset: Int) -> (UInt64, Int)? {
        guard offset < bytes.count else { return nil }
        let first = bytes[offset]
        var mask: UInt8 = 0x80
        var length = 1
        while length <= 8, mask > 0 {
            if (first & mask) != 0 {
                var size = UInt64(first) & UInt64(mask - 1)
                for i in 1..<length where offset + i < bytes.count {
                    size = (size << 8) | UInt64(bytes[offset + i])
                }
                return (size, length)
            }
            mask >>= 1
            length += 1
        }
        return nil
    }

    /// Parse SeekHead → Seek entries whose SeekID is Cues (0x1C53BB6B).
    private static func seekHeadCuePositions(in head: Data) -> [Int64] {
        guard head.count >= 64 else { return [] }
        var results: [Int64] = []
        head.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = head.count
            var i = 0
            while i + 12 < count {
                if baseAddress[i] == 0x53, baseAddress[i + 1] == 0xAB,
                   i + 8 < count,
                   baseAddress[i + 3] == 0x84,
                   baseAddress[i + 4] == 0x1C, baseAddress[i + 5] == 0x53,
                   baseAddress[i + 6] == 0xBB, baseAddress[i + 7] == 0x6B {
                    for j in (i + 8)..<min(count, i + 32) {
                        if baseAddress[j] == 0x53, baseAddress[j + 1] == 0xAC, j + 3 < count {
                            let size = Int(baseAddress[j + 2])
                            if size > 0, size <= 8, j + 3 + size <= count {
                                var value: UInt64 = 0
                                for k in 0..<size {
                                    value = (value << 8) | UInt64(baseAddress[j + 3 + k])
                                }
                                results.append(Int64(value))
                            }
                        }
                    }
                }
                i += 1
            }
        }
        return results
    }

    private static func findAll(elementID: [UInt8], in data: Data) -> [Int] {
        guard !elementID.isEmpty, data.count >= elementID.count else { return [] }
        var positions: [Int] = []
        let n = data.count
        let m = elementID.count
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var i = 0
            while i + m <= n {
                var match = true
                for j in 0..<m {
                    if baseAddress[i + j] != elementID[j] {
                        match = false
                        break
                    }
                }
                if match {
                    positions.append(i)
                    i += m
                } else {
                    i += 1
                }
            }
        }
        return positions
    }
}

#if DEBUG
extension MKVSeekBootstrap {
    public static func testMediaOffsetForPlaybackTime(
        seconds: Double,
        durationSeconds: Double,
        head: Data,
        tail: Data,
        tailMediaOffset: Int64,
        mediaByteLength: Int64
    ) -> Int64? {
        mediaOffsetForPlaybackTime(
            seconds: seconds,
            durationSeconds: durationSeconds,
            head: head,
            tail: tail,
            tailMediaOffset: tailMediaOffset,
            mediaByteLength: mediaByteLength
        )
    }
}
#endif
