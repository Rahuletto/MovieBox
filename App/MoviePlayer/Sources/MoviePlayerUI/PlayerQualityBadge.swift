import AppKit
import SwiftUI

public enum PlayerAudioFormat: String, Sendable, Codable {
    case dolbyAtmos = "Atmos"
}

/// HDR / Dolby badges shown in the playback HUD pill (asset images bundled in CorePlayer).
public enum PlayerQualityBadgeKind: String, Sendable, Equatable, Hashable {
    case hdr
    case dolbyVision
    case dolbyAtmos

    var assetBaseName: String {
        switch self {
        case .hdr: "badge-hdr"
        case .dolbyVision: "badge-dolby-vision"
        case .dolbyAtmos: "badge-dolby-atmos"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .hdr: "HDR"
        case .dolbyVision: "Dolby Vision"
        case .dolbyAtmos: "Dolby Atmos"
        }
    }

    func displayWidth() -> CGFloat {
        switch self {
        case .hdr: 36
        // Source asset 372×138 — preserve aspect at 18pt height.
        case .dolbyVision: 49
        case .dolbyAtmos: 42
        }
    }

    func displayHeight() -> CGFloat {
        switch self {
        case .hdr: 16
        case .dolbyVision, .dolbyAtmos: 18
        }
    }
}

extension PlayerState {
    /// Badges to show in the opening playback HUD pill.
    public var qualityBadgeKinds: [PlayerQualityBadgeKind] {
        var kinds: [PlayerQualityBadgeKind] = []
        switch hdrType {
        case .dolbyVision, .dolbyVisionWithHDR10:
            kinds.append(.dolbyVision)
        case .hdr, .hdr10, .hdr10Plus, .hlg:
            kinds.append(.hdr)
        case nil:
            break
        }
        if audioFormat == .dolbyAtmos {
            kinds.append(.dolbyAtmos)
        }
        return kinds
    }
}

struct PlayerQualityBadgeImage: View {
    let kind: PlayerQualityBadgeKind

    var body: some View {
        bundleImage
            .playerGlassBadgeImage()
            .frame(width: kind.displayWidth(), height: kind.displayHeight())
    }

    private var bundleImage: Image {
        if let nsImage = Self.loadImage(named: kind.assetBaseName) {
            return Image(nsImage: nsImage)
        }
        return Image(systemName: "sparkles")
    }

    private static func loadImage(named baseName: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: baseName, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        return image
    }
}
