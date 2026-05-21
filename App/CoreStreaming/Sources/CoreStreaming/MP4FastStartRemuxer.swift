import Foundation

/// Synthesizes a virtual fast-start MP4 layout from a moov atom + mdat stream.
/// AVPlayer sees moov at byte 0; actual video data is served progressively from disk.
public struct MP4FastStartRemuxer {

    public struct RemuxedLayout: Sendable {
        /// The synthesized header to prepend: ftyp (if present) + moov with patched offsets + mdat box header.
        public let syntheticHeader: Data
        /// The byte offset in the ORIGINAL torrent file (relative to start of media file)
        /// where mdat *content* begins (i.e. the byte right after the original mdat box header).
        public let mdatContentTorrentOffset: Int64
        /// Total virtual file length presented to AVPlayer.
        public let virtualFileLength: Int64
    }

    /// Given the raw moov atom bytes (already downloaded from tail) and the file geometry,
    /// produce a remuxed layout where moov precedes mdat.
    ///
    /// - Parameters:
    ///   - moovData: Raw bytes of the moov box (including its 8-byte size+type header).
    ///   - ftypData: Optional ftyp box bytes from the file head (first ~32 bytes).
    ///   - originalFileLength: Total byte length of the video file.
    ///   - originalMoovOffset: Offset of the moov box within the original media file
    ///                         (for diagnostics; not consumed by patching).
    ///   - mdatOffset: Byte offset within the original media file where the mdat *box header* starts.
    ///   - mdatLength: Length of the mdat content (i.e. mdat box size minus its 8-byte header).
    /// - Returns: A RemuxedLayout, or nil if the moov atom cannot be parsed/patched.
    public static func buildLayout(
        moovData: Data,
        ftypData: Data?,
        originalFileLength: Int64,
        originalMoovOffset: Int64,
        mdatOffset: Int64,
        mdatLength: Int64
    ) -> RemuxedLayout? {
        guard moovData.count >= 8 else { return nil }
        guard mdatLength > 0 else { return nil }

        // 1. Build the synthetic prefix: [ftyp?] + [patched moov]
        var prefix = Data()
        if let ftyp = ftypData {
            prefix.append(ftyp)
        }

        // 2. Patch the moov atom's stco/co64 chunk offset tables.
        //    Every chunk offset currently points into the original file layout.
        //    After remux, mdat content will start at (prefix.count + moovData.count + 8).
        //    The +8 is for the new mdat box header we synthesize after moov.
        let newMdatContentStart = Int64(prefix.count) + Int64(moovData.count) + 8
        let originalMdatContentStart = mdatOffset + 8 // skip the original mdat box header
        let delta = newMdatContentStart - originalMdatContentStart

        guard let patchedMoov = patchChunkOffsets(moovData: moovData, delta: delta) else {
            return nil
        }
        prefix.append(patchedMoov)

        // 3. Append a mdat box header pointing to the actual content length.
        //    If (mdatLength + 8) fits in UInt32, use a 32-bit size; otherwise use 64-bit large-size form.
        let totalMdatBoxSize = mdatLength + 8
        if totalMdatBoxSize <= Int64(UInt32.max) {
            var mdatHeader = Data(count: 8)
            mdatHeader.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                let size = UInt32(totalMdatBoxSize).bigEndian
                let type = UInt32(0x6D646174).bigEndian // 'mdat'
                base.storeBytes(of: size, as: UInt32.self)
                base.advanced(by: 4).storeBytes(of: type, as: UInt32.self)
            }
            prefix.append(mdatHeader)
        } else {
            // 64-bit large size form: size32=1, type='mdat', then UInt64 large-size
            // total box header = 16 bytes; need to recompute newMdatContentStart and re-patch
            // To keep things simple, fail fast on absurdly large mdat (>4GB) for now.
            // (Re-patching is possible but very rare in practice for torrent MP4 files.)
            TorrentLog.warn("[Remux] mdat too large (\(mdatLength) bytes) for 32-bit box header; skipping remux")
            return nil
        }

        let virtualFileLength = Int64(prefix.count) + mdatLength

        TorrentLog.info(
            "[Remux] layout built — header=\(prefix.count)B moov=\(moovData.count)B mdat=\(mdatLength)B virtual=\(virtualFileLength)B delta=\(delta)"
        )

        return RemuxedLayout(
            syntheticHeader: prefix,
            mdatContentTorrentOffset: originalMdatContentStart,
            virtualFileLength: virtualFileLength
        )
    }

    // MARK: - Chunk Offset Patcher

    /// Walks the moov atom and patches all stco/co64 boxes by adding `delta` to each entry.
    private static func patchChunkOffsets(moovData: Data, delta: Int64) -> Data? {
        var patched = moovData
        patchBoxRecursive(data: &patched, range: 0..<patched.count, delta: delta)
        return patched
    }

    private static func patchBoxRecursive(data: inout Data, range: Range<Int>, delta: Int64) {
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            let size32 = Int(readUInt32BE(data, offset: offset))
            let boxType = readFourCC(data, offset: offset + 4)

            var boxSize = size32
            var headerSize = 8
            if size32 == 1, offset + 16 <= range.upperBound {
                let large = readUInt64BE(data, offset: offset + 8)
                boxSize = Int(large)
                headerSize = 16
            }
            guard boxSize >= headerSize, offset + boxSize <= range.upperBound else { break }

            let bodyStart = offset + headerSize

            switch boxType {
            case "stco":
                // 32-bit chunk offsets: version(1) + flags(3) + entry_count(4) + entries(4*N)
                guard bodyStart + 8 <= offset + boxSize else { break }
                let entryCount = Int(readUInt32BE(data, offset: bodyStart + 4))
                let entriesStart = bodyStart + 8
                for i in 0..<entryCount {
                    let entryOffset = entriesStart + i * 4
                    guard entryOffset + 4 <= offset + boxSize else { break }
                    let original = Int64(readUInt32BE(data, offset: entryOffset))
                    let newValue = original + delta
                    let clamped = UInt32(clamping: newValue)
                    writeUInt32BE(&data, offset: entryOffset, value: clamped)
                }

            case "co64":
                // 64-bit chunk offsets
                guard bodyStart + 8 <= offset + boxSize else { break }
                let entryCount = Int(readUInt32BE(data, offset: bodyStart + 4))
                let entriesStart = bodyStart + 8
                for i in 0..<entryCount {
                    let entryOffset = entriesStart + i * 8
                    guard entryOffset + 8 <= offset + boxSize else { break }
                    let originalBits = readUInt64BE(data, offset: entryOffset)
                    let original = Int64(bitPattern: originalBits)
                    let patchedValue = UInt64(bitPattern: original + delta)
                    writeUInt64BE(&data, offset: entryOffset, value: patchedValue)
                }

            case "moov", "trak", "mdia", "minf", "stbl", "udta", "edts":
                // Container boxes — recurse
                patchBoxRecursive(data: &data, range: bodyStart..<(offset + boxSize), delta: delta)

            default:
                break
            }

            offset += boxSize
        }
    }

    // MARK: - Byte Helpers

    private static func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { ptr in
            let raw = ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            return UInt32(bigEndian: raw)
        }
    }

    private static func readUInt64BE(_ data: Data, offset: Int) -> UInt64 {
        data.withUnsafeBytes { ptr in
            let raw = ptr.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            return UInt64(bigEndian: raw)
        }
    }

    private static func writeUInt32BE(_ data: inout Data, offset: Int, value: UInt32) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { bytes in
            data.replaceSubrange(offset..<(offset + 4), with: bytes)
        }
    }

    private static func writeUInt64BE(_ data: inout Data, offset: Int, value: UInt64) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { bytes in
            data.replaceSubrange(offset..<(offset + 8), with: bytes)
        }
    }

    private static func readFourCC(_ data: Data, offset: Int) -> String {
        guard offset + 4 <= data.count else { return "????" }
        let bytes: [UInt8] = [data[data.startIndex + offset],
                              data[data.startIndex + offset + 1],
                              data[data.startIndex + offset + 2],
                              data[data.startIndex + offset + 3]]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}
