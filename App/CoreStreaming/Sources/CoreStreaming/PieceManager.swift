import Foundation
import CryptoKit

// MARK: - Piece Manager (Streaming Priority)

public enum PieceReceiveOutcome: Sendable {
    case incomplete
    case verified
    case rejected
}

public actor PieceManager {
    public let pieceCount: Int
    public let pieceLength: Int64
    public let totalSize: Int64
    public let blockSize: UInt32 = 16384
    public let streamFirstPiece: Int
    public let streamLastPiece: Int
    public let streamTailPieces: [Int]
    public let streamMediaByteOffset: Int64
    public let streamMediaByteLength: Int64

    private var pieceHashes: [Data] = []
    private var downloadedPieces: Set<UInt32> = []
    /// Pieces loaded from a resume bitmap — data may not actually be on disk, so
    /// the first incoming block must re-verify. Once verified they are removed here.
    private var resumeSeededPieces: Set<UInt32> = []
    private var pendingRequests: [BlockRequest: Date] = [:]
    private var pieceBuffers: [UInt32: Data] = [:]
    private var receivedBlockOffsets: [UInt32: Set<UInt32>] = [:]
    /// Pieces AVPlayer recently requested via range reads (newest first).
    private var playerHotPieces: [UInt32] = []
    private var playbackAnchorPiece: UInt32?
    /// Scrubber target — kept separate so AVPlayer/FFmpeg sequential reads stay prioritized.
    private var seekAnchorPiece: UInt32?
    private var indexBootstrapCompleted = false
    /// Set only from scrubber `prioritizePlayback` — not AVPlayer tail/head range probes.
    private var userInitiatedSeek = false

    private static let criticalReadAheadPieceCount = 4
    private static let warmReadAheadPieceCount = 16
    private static let maxHotPieces = criticalReadAheadPieceCount + warmReadAheadPieceCount + 8
    /// After a scrubber seek, fetch a real playback window from the anchor so AVPlayer can resume there.
    private static let maxSequentialAheadFromAnchor = 512
    private static let maxSequentialBehindFromAnchor = 8
    /// Pieces from file start still treated as "start" for bootstrap (not a mid-file seek).
    private static let midFileSeekPieceThreshold = 4

    private func midFilePlaybackWindow(for anchorInt: Int) -> ClosedRange<Int> {
        let lower = max(streamFirstPiece, anchorInt - Self.maxSequentialBehindFromAnchor)
        let upper = min(streamLastPiece, anchorInt + Self.maxSequentialAheadFromAnchor)
        return lower...upper
    }

    public init(
        pieceCount: Int,
        pieceLength: Int64,
        totalSize: Int64,
        piecesHash: Data,
        streamFirstPiece: Int = 0,
        streamLastPiece: Int? = nil,
        streamTailPieces: [Int]? = nil,
        streamMediaByteOffset: Int64 = 0,
        streamMediaByteLength: Int64? = nil
    ) {
        self.pieceCount = pieceCount
        self.pieceLength = pieceLength
        self.totalSize = totalSize
        self.streamFirstPiece = streamFirstPiece
        self.streamMediaByteOffset = streamMediaByteOffset
        self.streamMediaByteLength = streamMediaByteLength ?? max(0, totalSize - streamMediaByteOffset)
        if let streamTailPieces, !streamTailPieces.isEmpty {
            self.streamTailPieces = streamTailPieces
            self.streamLastPiece = streamTailPieces.max() ?? max(0, pieceCount - 1)
        } else {
            let last = streamLastPiece ?? max(0, pieceCount - 1)
            self.streamLastPiece = last
            self.streamTailPieces = [last]
        }

        let cleanHash = Data(piecesHash)
        var index = 0
        while index + 20 <= cleanHash.count {
            pieceHashes.append(cleanHash[index..<index + 20])
            index += 20
        }
    }

    public func setInitialDownloadedPieces(_ pieces: Set<UInt32>) {
        downloadedPieces = pieces
        resumeSeededPieces = pieces
    }

    public func clearDownloadedPieces(in range: ClosedRange<Int>) {
        for index in range {
            let piece = UInt32(index)
            downloadedPieces.remove(piece)
            resumeSeededPieces.remove(piece)
            resetPiece(piece)
        }
    }

    public func setIndexBootstrapCompleted() {
        indexBootstrapCompleted = true
    }

    private static let duplicateRequestTimeout: TimeInterval = 2.0

    private func isPieceCritical(_ pieceIndex: UInt32) -> Bool {
        guard let anchor = playbackAnchorPiece else {
            return playerHotPieces.prefix(Self.criticalReadAheadPieceCount).contains(pieceIndex)
        }
        if pieceIndex >= anchor && pieceIndex <= anchor + UInt32(Self.criticalReadAheadPieceCount) {
            return true
        }
        return playerHotPieces.prefix(Self.criticalReadAheadPieceCount).contains(pieceIndex)
    }

    private func prioritizedPiecesForPeer(peerBitfield: Data) -> [UInt32] {
        var result: [UInt32] = []
        var seen = Set<UInt32>()
        
        func appendFrom(_ list: [UInt32]) {
            for idx in list {
                guard !downloadedPieces.contains(idx) else { continue }
                guard !seen.contains(idx) else { continue }
                if !peerBitfield.isEmpty, !peerHasPiece(idx, in: peerBitfield) { continue }
                result.append(idx)
                seen.insert(idx)
            }
        }
        
        let end = min(streamLastPiece, pieceCount - 1)

        if userInitiatedSeek,
           let seek = seekAnchorPiece,
           let seekInt = seekAnchorPiece.map({ Int($0) }),
           isMidFileSeekAnchor(seekInt),
           seekInt <= end {
            
            // 1. Prioritize index bootstrap if head/tail are missing (cues needed by ffmpeg)
            if needsIndexBootstrap() {
                appendFrom(buildBootstrapPriorityOrder())
            }
            
            // 2. First append the critical seek target pieces (seek ... seek + criticalReadAhead)
            var criticalSeekPieces: [UInt32] = []
            let criticalEnd = min(UInt32(streamLastPiece), seek + UInt32(Self.criticalReadAheadPieceCount))
            for p in seek...criticalEnd {
                criticalSeekPieces.append(p)
            }
            appendFrom(criticalSeekPieces)
            
            // 3. Then append the rest of the seek window neighborhood
            let lower = max(streamFirstPiece, seekInt - 8)
            let upper = min(streamLastPiece, seekInt + 32)
            appendFrom((lower...seekInt).reversed().map { UInt32($0) })
            appendFrom((seekInt...upper).map { UInt32($0) })
            
            return result
        }

        // Normal playback priority order
        appendFrom(buildPlaybackPriorityOrder())

        if needsIndexBootstrap() {
            appendFrom(buildBootstrapPriorityOrder())
        }

        let anchorInt = playbackAnchorPiece.map { Int($0) } ?? streamFirstPiece
        guard anchorInt <= end else { return result }

        if anchorInt <= end {
            appendFrom((anchorInt...end).map { UInt32($0) })
        }
        if anchorInt > streamFirstPiece {
            appendFrom((streamFirstPiece..<anchorInt).map { UInt32($0) })
        }

        return result
    }

    private func isMidFileSeekAnchor(_ anchorInt: Int) -> Bool {
        anchorInt > streamFirstPiece + Self.midFileSeekPieceThreshold
    }

    public func getNextRequest(
        peerBitfield: Data = Data(),
        connectionOutstanding: Set<BlockRequest> = []
    ) -> BlockRequest? {
        let candidates = prioritizedPiecesForPeer(peerBitfield: peerBitfield)
        let now = Date.now

        // Loop 1: Find first non-pending block
        for pieceIndex in candidates {
            let pieceSize = pieceSize(for: pieceIndex)
            let blockCount = Int((pieceSize + Int64(blockSize) - 1) / Int64(blockSize))
            
            for blockIndex in 0..<blockCount {
                let offset = UInt32(blockIndex) * blockSize
                if receivedBlockOffsets[pieceIndex]?.contains(offset) == true {
                    continue
                }
                
                let length = min(blockSize, UInt32(pieceSize) - offset)
                let request = BlockRequest(pieceIndex: pieceIndex, offset: offset, length: length)
                
                if pendingRequests[request] == nil {
                    pendingRequests[request] = now
                    return request
                }
            }
        }

        // Loop 2: Critical window duplicate request hotswapping
        for pieceIndex in candidates {
            guard isPieceCritical(pieceIndex) else { continue }
            
            let pieceSize = pieceSize(for: pieceIndex)
            let blockCount = Int((pieceSize + Int64(blockSize) - 1) / Int64(blockSize))
            
            for blockIndex in 0..<blockCount {
                let offset = UInt32(blockIndex) * blockSize
                if receivedBlockOffsets[pieceIndex]?.contains(offset) == true {
                    continue
                }
                
                let length = min(blockSize, UInt32(pieceSize) - offset)
                let request = BlockRequest(pieceIndex: pieceIndex, offset: offset, length: length)
                
                if connectionOutstanding.contains(request) {
                    continue
                }
                
                if let sentTime = pendingRequests[request],
                   now.timeIntervalSince(sentTime) > Self.duplicateRequestTimeout {
                    pendingRequests[request] = now
                    TorrentLog.info("[PieceManager] Hotswapping critical block p\(pieceIndex)@\(offset) (pending \(String(format: "%.1f", now.timeIntervalSince(sentTime)))s)")
                    return request
                }
            }
        }

        return nil
    }

    public func recycleRequests(_ requests: [BlockRequest]) {
        for request in requests {
            pendingRequests.removeValue(forKey: request)
        }
    }

    public func isRequestStillInPlaybackWindow(_ request: BlockRequest) -> Bool {
        let piece = request.pieceIndex
        if downloadedPieces.contains(piece) { return false }
        
        // Keep index bootstrap requests alive so ffmpeg can read cues/headers
        if needsIndexBootstrap() {
            if piece == UInt32(streamFirstPiece) || streamTailPieces.contains(Int(piece)) {
                return true
            }
        }
        
        if userInitiatedSeek,
           let seek = seekAnchorPiece,
           isMidFileSeekAnchor(Int(seek)) {
            let lower = max(streamFirstPiece, Int(seek) - 8)
            let upper = min(streamLastPiece, Int(seek) + 32)
            return (lower...upper).contains(Int(piece))
        }
        if Set(buildPlaybackPriorityOrder()).contains(piece) { return true }
        return false
    }

    public func playbackAnchorPieceIndex() -> UInt32? {
        playbackAnchorPiece
    }

    public func pieceIndicesForMediaOffset(mediaOffset: Int64, length: Int) -> [UInt32] {
        pieceIndicesCovering(mediaOffset: mediaOffset, length: length)
    }

    public func markBlockReceived(pieceIndex: UInt32, offset: UInt32, block: Data) -> PieceReceiveOutcome {
        pendingRequests.removeValue(forKey: BlockRequest(pieceIndex: pieceIndex, offset: offset, length: 0))

        if downloadedPieces.contains(pieceIndex) {
            // A resume-seeded piece might not actually be on disk — re-download to verify.
            // A genuinely verified piece means a peer sent a block late (e.g. after seek).
            // Ignore it — the data is already on disk and correct.
            if resumeSeededPieces.contains(pieceIndex) {
                downloadedPieces.remove(pieceIndex)
                resumeSeededPieces.remove(pieceIndex)
                resetPiece(pieceIndex)
            } else {
                return .incomplete
            }
        }

        let expectedSize = Int(pieceSize(for: pieceIndex))
        if pieceBuffers[pieceIndex] == nil {
            pieceBuffers[pieceIndex] = Data(count: expectedSize)
        }

        guard var buffer = pieceBuffers[pieceIndex] else { return .incomplete }

        let start = Int(offset)
        let end = start + block.count
        guard start >= 0, end <= buffer.count else { return .incomplete }

        buffer.replaceSubrange(start..<end, with: block)
        pieceBuffers[pieceIndex] = buffer

        var offsets = receivedBlockOffsets[pieceIndex] ?? []
        offsets.insert(offset)
        receivedBlockOffsets[pieceIndex] = offsets

        guard isPieceFullyReceived(pieceIndex: pieceIndex, expectedSize: expectedSize) else {
            return .incomplete
        }

        guard verifyPiece(pieceIndex: pieceIndex, data: buffer) else {
            return .rejected
        }

        return .verified
    }

    public func cancelPendingRequests() -> [BlockRequest] {
        let requests = Array(pendingRequests.keys)
        pendingRequests.removeAll()
        return requests
    }

    public func isPieceDownloaded(_ pieceIndex: UInt32) -> Bool {
        downloadedPieces.contains(pieceIndex)
    }

    public func pieceProgress(pieceIndex: UInt32) -> Double {
        if downloadedPieces.contains(pieceIndex) {
            return 1.0
        }
        guard let offsets = receivedBlockOffsets[pieceIndex] else { return 0.0 }
        let size = Double(pieceSize(for: pieceIndex))
        guard size > 0 else { return 0.0 }
        
        let received = offsets.reduce(0.0) { sum, offset in
            let blockLen = min(Double(blockSize), size - Double(offset))
            return sum + max(0.0, blockLen)
        }
        return min(1.0, received / size)
    }

    public func progress() -> Double {
        guard pieceCount > 0 else { return 0 }
        return Double(downloadedPieces.count) / Double(pieceCount)
    }

    public func downloadedCount() -> Int {
        downloadedPieces.count
    }

    public func pendingRequestCount() -> Int {
        pendingRequests.count
    }

    public func takePieceData(_ pieceIndex: UInt32) -> Data? {
        defer { pieceBuffers.removeValue(forKey: pieceIndex) }
        return pieceBuffers[pieceIndex]
    }

    /// Called when AVPlayer requests a byte range — boosts torrent piece priority for that span.
    public func notePlayerRead(mediaOffset: Int64, length: Int) {
        let indices = pieceIndicesCovering(mediaOffset: mediaOffset, length: length)
        guard !indices.isEmpty else { return }

        if userInitiatedSeek,
           let seek = seekAnchorPiece {
            let lower = max(0, Int(seek) - 8)
            let upper = Int(seek) + 32
            let isNearSeek = indices.contains { (lower...upper).contains(Int($0)) }
            
            if isNearSeek {
                let resetLower = max(0, Int(seek) - 4)
                let resetUpper = Int(seek) + 4
                let isAtSeekTarget = indices.contains { (resetLower...resetUpper).contains(Int($0)) }
                let allPiecesDownloaded = indices.allSatisfy { downloadedPieces.contains($0) }
                if isAtSeekTarget && allPiecesDownloaded {
                    userInitiatedSeek = false
                    seekAnchorPiece = nil
                }
            } else {
                return
            }
        }

        playbackAnchorPiece = indices.first

        var expanded: [UInt32] = []
        for index in indices {
            if !expanded.contains(index) {
                expanded.append(index)
            }
        }
        if let last = indices.last {
            for ahead in 1...Self.warmReadAheadPieceCount {
                let next = last + UInt32(ahead)
                guard Int(next) < pieceCount else { break }
                guard next <= UInt32(streamLastPiece) else { break }
                expanded.append(next)
            }
        }

        for index in expanded.reversed() {
            playerHotPieces.removeAll { $0 == index }
            playerHotPieces.insert(index, at: 0)
        }
        if playerHotPieces.count > Self.maxHotPieces {
            playerHotPieces.removeLast(playerHotPieces.count - Self.maxHotPieces)
        }
    }

    public func playerHotPieceCount() -> Int {
        playerHotPieces.count
    }

    private func buildPlaybackPriorityOrder() -> [UInt32] {
        guard let playbackAnchorPiece else { return playerHotPieces }
        var priority: [UInt32] = []
        func append(_ index: UInt32) {
            guard Int(index) >= streamFirstPiece, Int(index) <= streamLastPiece else { return }
            guard !priority.contains(index) else { return }
            priority.append(index)
        }

        for index in playerHotPieces.prefix(Self.criticalReadAheadPieceCount + 1) {
            append(index)
        }

        for offset in 0...Self.criticalReadAheadPieceCount {
            append(playbackAnchorPiece + UInt32(offset))
        }

        for index in playerHotPieces.dropFirst(Self.criticalReadAheadPieceCount + 1) {
            append(index)
        }
        return priority
    }

    private func needsIndexBootstrap() -> Bool {
        if !downloadedPieces.contains(UInt32(streamFirstPiece)) {
            return true
        }
        for piece in streamTailPieces where !downloadedPieces.contains(UInt32(piece)) {
            return true
        }
        return false
    }

    /// Scrubber-only — does not move `playbackAnchorPiece` (FFmpeg/AVPlayer read cursor).
    public func markUserSeekPlayback(atMediaOffset mediaOffset: Int64, length: Int) {
        let indices = pieceIndicesCovering(mediaOffset: mediaOffset, length: length)
        if let first = indices.first {
            seekAnchorPiece = first
            playbackAnchorPiece = first
        }
        boostHotPieces(for: indices)
        userInitiatedSeek = true
    }

    private func boostHotPieces(for indices: [UInt32]) {
        guard !indices.isEmpty else { return }
        var expanded: [UInt32] = []
        for index in indices where !expanded.contains(index) {
            expanded.append(index)
        }
        if let last = indices.last {
            for ahead in 1...Self.warmReadAheadPieceCount {
                let next = last + UInt32(ahead)
                guard Int(next) <= streamLastPiece else { break }
                expanded.append(next)
            }
        }
        for index in expanded.reversed() {
            playerHotPieces.removeAll { $0 == index }
            playerHotPieces.insert(index, at: 0)
        }
        if playerHotPieces.count > Self.maxHotPieces {
            playerHotPieces.removeLast(playerHotPieces.count - Self.maxHotPieces)
        }
    }

    public func needsIndexBootstrapForLogging() -> Bool {
        needsIndexBootstrap()
    }

    private func buildBootstrapPriorityOrder() -> [UInt32] {
        var priority: [UInt32] = []
        func append(_ index: UInt32) {
            guard !priority.contains(index) else { return }
            priority.append(index)
        }

        for index in playerHotPieces {
            append(index)
        }
        append(UInt32(streamFirstPiece))
        for index in buildMissingTailPiecesNearestEOF() {
            append(index)
        }
        if let last = missingStreamLastPiece() {
            append(last)
        }
        return priority
    }

    /// Unverified tail pieces nearest EOF, excluding the final partial piece.
    private func buildMissingTailPiecesNearestEOF() -> [UInt32] {
        guard !streamTailPieces.isEmpty else { return [] }
        return streamTailPieces
            .filter { $0 != streamLastPiece && !downloadedPieces.contains(UInt32($0)) }
            .sorted(by: >)
            .map { UInt32($0) }
    }

    private func missingStreamLastPiece() -> UInt32? {
        let last = UInt32(streamLastPiece)
        guard !downloadedPieces.contains(last) else { return nil }
        return last
    }

    private func pieceIndicesCovering(mediaOffset: Int64, length: Int) -> [UInt32] {
        guard length > 0, mediaOffset >= 0 else { return [] }
        let span = min(Int64(length), streamMediaByteLength - mediaOffset)
        guard span > 0 else { return [] }

        let torrentStart = streamMediaByteOffset + mediaOffset
        let torrentEnd = torrentStart + span - 1
        let first = max(streamFirstPiece, min(streamLastPiece, Int(torrentStart / pieceLength)))
        let last = max(streamFirstPiece, min(streamLastPiece, Int(torrentEnd / pieceLength)))
        guard first <= last else { return [] }
        return (first...last).map { UInt32($0) }
    }

    private func isPieceFullyReceived(pieceIndex: UInt32, expectedSize: Int) -> Bool {
        let blockCount = Int((Int64(expectedSize) + Int64(blockSize) - 1) / Int64(blockSize))
        guard let offsets = receivedBlockOffsets[pieceIndex], offsets.count >= blockCount else {
            return false
        }
        for blockIndex in 0..<blockCount {
            let offset = UInt32(blockIndex) * blockSize
            if !offsets.contains(offset) { return false }
        }
        return true
    }

    private func resetPiece(_ pieceIndex: UInt32) {
        pieceBuffers[pieceIndex] = nil
        receivedBlockOffsets[pieceIndex] = nil
        pendingRequests = pendingRequests.filter { $0.key.pieceIndex != pieceIndex }
    }

    private func pieceSize(for pieceIndex: UInt32) -> Int64 {
        let index = Int(pieceIndex)
        if index == pieceCount - 1 {
            return totalSize - (Int64(index) * pieceLength)
        }
        return pieceLength
    }

    private func peerHasPiece(_ pieceIndex: UInt32, in bitfield: Data) -> Bool {
        let byteIndex = Int(pieceIndex / 8)
        let bitIndex = Int(pieceIndex % 8)
        guard byteIndex < bitfield.count else { return false }
        return (bitfield[byteIndex] & (1 << (7 - bitIndex))) != 0
    }

    private func verifyPiece(pieceIndex: UInt32, data: Data) -> Bool {
        guard Int(pieceIndex) < pieceHashes.count else { return false }

        let computedHash = Data(Insecure.SHA1.hash(data: data))
        guard computedHash == pieceHashes[Int(pieceIndex)] else {
            TorrentLog.debug("[PieceManager] Hash mismatch on piece \(pieceIndex), retrying")
            resetPiece(pieceIndex)
            return false
        }

        downloadedPieces.insert(pieceIndex)
        resumeSeededPieces.remove(pieceIndex)
        pieceBuffers.removeValue(forKey: pieceIndex)
        receivedBlockOffsets.removeValue(forKey: pieceIndex)
        trimPieceBuffers(keeping: pieceIndex)
        advancePlaybackAnchor()
        return true
    }

    /// After a verified piece extends the contiguous downloaded region ahead of the anchor,
    /// advance the anchor so the next undownloaded frontier gets critical priority.
    private func advancePlaybackAnchor() {
        guard let anchor = playbackAnchorPiece else { return }
        let end = min(UInt32(streamLastPiece), UInt32(pieceCount - 1))
        var newAnchor = anchor
        while newAnchor <= end && downloadedPieces.contains(newAnchor) {
            newAnchor += 1
        }
        guard newAnchor > anchor else { return }

        playbackAnchorPiece = newAnchor

        // Seed the hot list with the next frontier pieces so they get duplicate-request
        // hot-swapping in Loop 2 of getNextRequest.
        let hotEnd = min(end, newAnchor + UInt32(Self.warmReadAheadPieceCount))
        for piece in newAnchor...hotEnd {
            guard !downloadedPieces.contains(piece) else { continue }
            playerHotPieces.removeAll { $0 == piece }
            playerHotPieces.insert(piece, at: 0)
        }
        if playerHotPieces.count > Self.maxHotPieces {
            playerHotPieces.removeLast(playerHotPieces.count - Self.maxHotPieces)
        }
    }

    private func trimPieceBuffers(keeping current: UInt32) {
        let maxBuffers = 64
        guard pieceBuffers.count > maxBuffers else { return }

        let tailSet = Set(streamTailPieces.map { UInt32($0) })
        let hotSet = Set(playerHotPieces)

        let candidates = pieceBuffers.keys.filter { key in
            key != current && !tailSet.contains(key) && !hotSet.contains(key)
        }

        for key in candidates {
            resetPiece(key)
            if pieceBuffers.count <= maxBuffers { break }
        }
    }
}

public struct BlockRequest: Hashable, Sendable {
    public let pieceIndex: UInt32
    public let offset: UInt32
    public let length: UInt32

    public init(pieceIndex: UInt32, offset: UInt32, length: UInt32) {
        self.pieceIndex = pieceIndex
        self.offset = offset
        self.length = length
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(pieceIndex)
        hasher.combine(offset)
    }

    public static func == (lhs: BlockRequest, rhs: BlockRequest) -> Bool {
        lhs.pieceIndex == rhs.pieceIndex && lhs.offset == rhs.offset
    }
}
