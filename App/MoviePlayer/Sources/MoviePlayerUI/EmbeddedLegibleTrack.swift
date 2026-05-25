import AVFoundation
import Foundation

/// One subtitle track exposed by AVFoundation on the current player item (`.legible`).
public struct EmbeddedLegibleTrack: Sendable, Identifiable, Hashable {
    public let index: Int
    public let displayName: String
    public let language: String

    public var id: Int { index }

    public init(index: Int, displayName: String, language: String) {
        self.index = index
        self.displayName = displayName
        self.language = language
    }
}
