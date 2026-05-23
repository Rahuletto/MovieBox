import Foundation

/// Matroska index regions to prioritize (Cues element and SeekHead targets).
enum MKVSeekBootstrap {
    private static let cuesElementID: [UInt8] = [0x1C, 0x53, 0xBB, 0x6B]

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

    /// Parse SeekHead → Seek entries whose SeekID is Cues (0x1C53BB6B).
    private static func seekHeadCuePositions(in head: Data) -> [Int64] {
        guard head.count >= 64 else { return [] }
        var results: [Int64] = []
        let bytes = [UInt8](head)
        var i = 0
        while i + 12 < bytes.count {
            // SeekID element 0x53 0xAB, value length 4, value 1C 53 BB 6B
            if bytes[i] == 0x53, bytes[i + 1] == 0xAB,
               i + 8 < bytes.count,
               bytes[i + 3] == 0x84,
               bytes[i + 4] == 0x1C, bytes[i + 5] == 0x53,
               bytes[i + 6] == 0xBB, bytes[i + 7] == 0x6B {
                // SeekPosition 0x53 0xAC often follows within ~16 bytes
                for j in (i + 8)..<min(bytes.count, i + 32) {
                    if bytes[j] == 0x53, bytes[j + 1] == 0xAC, j + 3 < bytes.count {
                        let size = Int(bytes[j + 2])
                        if size > 0, size <= 8, j + 3 + size <= bytes.count {
                            var value: UInt64 = 0
                            for k in 0..<size {
                                value = (value << 8) | UInt64(bytes[j + 3 + k])
                            }
                            results.append(Int64(value))
                        }
                    }
                }
            }
            i += 1
        }
        return results
    }

    private static func findAll(elementID: [UInt8], in data: Data) -> [Int] {
        guard !elementID.isEmpty, data.count >= elementID.count else { return [] }
        let bytes = [UInt8](data)
        var positions: [Int] = []
        var i = 0
        while i + elementID.count <= bytes.count {
            if Array(bytes[i..<(i + elementID.count)]) == elementID {
                positions.append(i)
                i += elementID.count
            } else {
                i += 1
            }
        }
        return positions
    }
}
