import Foundation

/// Identifies which file inside a multi-file torrent is streamed to the player.
public struct TorrentStreamTarget: Sendable {
    public let file: TorrentFile
    /// Byte offset of this file within the torrent's piece-addressable layout.
    public let byteOffset: Int64
    public let byteLength: Int64
    public let firstPieceIndex: Int
    /// Last torrent piece overlapping the streamed file (often needed for MKV index/cues).
    public let lastPieceIndex: Int
    public let contentType: String

    public init(
        file: TorrentFile,
        byteOffset: Int64,
        byteLength: Int64,
        firstPieceIndex: Int,
        lastPieceIndex: Int,
        contentType: String
    ) {
        self.file = file
        self.byteOffset = byteOffset
        self.byteLength = byteLength
        self.firstPieceIndex = firstPieceIndex
        self.lastPieceIndex = lastPieceIndex
        self.contentType = contentType
    }

    /// AVPlayer probes the end of the file for container indexes (MKV cues, MP4 `moov`, etc.).
    public var needsTailProbeForPlayback: Bool {
        let ext = file.relativePath.lowercased()
        if ext.hasSuffix(".mkv") { return true }
        if ext.hasSuffix(".mp4") || ext.hasSuffix(".m4v") || ext.hasSuffix(".mov") { return true }
        if ext.hasSuffix(".webm") { return true }
        return contentType.contains("matroska")
    }

    /// MP4/MKV — used for UI labels only (no moov-on-disk playback gate).
    public var needsMP4MoovTailProbe: Bool {
        let ext = (file.relativePath as NSString).pathExtension.lowercased()
        if ext == "mp4" || ext == "m4v" || ext == "mov" { return true }
        return contentType.contains("mp4") || contentType.contains("quicktime")
    }

    /// Inclusive piece indices that must be verified before a download can be assembled.
    public var requiredPieceRange: ClosedRange<Int> {
        firstPieceIndex...lastPieceIndex
    }

    public var requiredPieceCount: Int {
        lastPieceIndex - firstPieceIndex + 1
    }

    public static func selectPrimary(from metadata: TorrentMetadata) -> TorrentStreamTarget {
        let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "avi", "mov", "webm", "ts", "m2ts"]

        let videoCandidates = metadata.files.filter { file in
            let ext = (file.relativePath as NSString).pathExtension.lowercased()
            return videoExtensions.contains(ext)
        }

        let chosen: TorrentFile
        if let largestVideo = videoCandidates.max(by: { $0.length < $1.length }) {
            chosen = largestVideo
        } else if let largestFile = metadata.files.max(by: { $0.length < $1.length }) {
            chosen = largestFile
        } else {
            chosen = metadata.files[0]
        }

        var offset: Int64 = 0
        for file in metadata.files {
            if file.relativePath == chosen.relativePath { break }
            offset += file.length
        }

        let firstPiece = Int(offset / metadata.pieceLength)
        let lastByte = offset + chosen.length - 1
        let lastPiece = Int(lastByte / metadata.pieceLength)
        let ext = (chosen.relativePath as NSString).pathExtension.lowercased()
        let mime: String
        switch ext {
        case "mkv": mime = "video/x-matroska"
        case "webm": mime = "video/webm"
        case "mov", "m4v": mime = "video/quicktime"
        default: mime = "video/mp4"
        }

        return TorrentStreamTarget(
            file: chosen,
            byteOffset: offset,
            byteLength: chosen.length,
            firstPieceIndex: firstPiece,
            lastPieceIndex: lastPiece,
            contentType: mime
        )
    }
}
