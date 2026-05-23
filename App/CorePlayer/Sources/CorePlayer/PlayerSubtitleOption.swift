import Foundation

/// Subtitle entry shown in the in-player subtitles sidebar.
public struct PlayerSubtitleOption: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let author: String
    public let language: String
    /// Remote download URL/path (SubDL). Empty for embedded tracks.
    public let downloadPath: String
    /// Subtitle stream index for `ffmpeg -map 0:s:N` when embedded in the video file.
    public let embeddedStreamIndex: Int?
    /// Local media file used for embedded extraction.
    public let sourceMediaPath: String?
    /// Use AVPlayer's legible media selection (works while streaming; no ffmpeg).
    public let usesAVPlayerLegible: Bool

    public var isEmbedded: Bool { embeddedStreamIndex != nil }

    public init(
        id: String,
        name: String,
        author: String,
        language: String,
        downloadPath: String,
        embeddedStreamIndex: Int? = nil,
        sourceMediaPath: String? = nil,
        usesAVPlayerLegible: Bool = false
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.language = language
        self.downloadPath = downloadPath
        self.embeddedStreamIndex = embeddedStreamIndex
        self.sourceMediaPath = sourceMediaPath
        self.usesAVPlayerLegible = usesAVPlayerLegible
    }
}
