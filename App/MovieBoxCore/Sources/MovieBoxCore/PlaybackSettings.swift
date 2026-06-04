import CorePlayer
import CoreStorage
import Foundation

public struct PlaybackSettings: Sendable {
    public let appearance: SubtitleAppearance
    public let fontSize: CGFloat

    public init(appearance: SubtitleAppearance, fontSize: CGFloat) {
        self.appearance = appearance
        self.fontSize = fontSize
    }

    public static func from(_ settings: AppSettings?) -> PlaybackSettings {
        PlaybackSettings(
            appearance: settings?.subtitleAppearance ?? .modern,
            fontSize: settings?.subtitleFontSizePoints ?? 20
        )
    }
}
