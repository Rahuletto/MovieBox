import Foundation

/// Remote subtitle entry shown in the in-player subtitles sidebar.
public struct PlayerSubtitleOption: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let author: String
    public let language: String
    public let downloadPath: String

    public init(id: String, name: String, author: String, language: String, downloadPath: String) {
        self.id = id
        self.name = name
        self.author = author
        self.language = language
        self.downloadPath = downloadPath
    }
}
