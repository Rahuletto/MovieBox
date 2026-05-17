import Foundation

/// A selectable streaming source shown in the player quality menu.
public struct PlaybackSourceOption: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let groupLabel: String
    public let qualityLabel: String
    public let languageLabel: String
    public let detailLine: String
    public let seeders: Int

    public init(
        id: String,
        title: String,
        groupLabel: String,
        qualityLabel: String,
        languageLabel: String,
        detailLine: String,
        seeders: Int
    ) {
        self.id = id
        self.title = title
        self.groupLabel = groupLabel
        self.qualityLabel = qualityLabel
        self.languageLabel = languageLabel
        self.detailLine = detailLine
        self.seeders = seeders
    }
}
