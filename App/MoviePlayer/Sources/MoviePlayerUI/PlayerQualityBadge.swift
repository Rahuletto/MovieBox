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

    var isDolbyLockup: Bool {
        self == .dolbyVision || self == .dolbyAtmos
    }

    func displayWidth() -> CGFloat {
        switch self {
        case .hdr: 36
        case .dolbyVision: 46
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
        if kind.isDolbyLockup {
            dolbyLockup
        } else {
            bundleImage
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: kind.displayWidth(), height: kind.displayHeight())
        }
    }

    private var bundleImage: Image {
        if let nsImage = Self.loadImage(named: kind.assetBaseName) {
            return Image(nsImage: nsImage)
        }
        return Image(systemName: "sparkles")
    }

    private var dolbyLockup: some View {
        let width = kind.displayWidth()
        let height = kind.displayHeight()
        let horizontalPadding: CGFloat = 3.5
        let verticalPadding: CGFloat = 2

        return bundleImage
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .frame(width: width - horizontalPadding * 2, height: height - verticalPadding * 2)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.black.opacity(0.45))
            )
            .frame(width: width, height: height)
    }

    private static func loadImage(named baseName: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: baseName, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        return image
    }
}
