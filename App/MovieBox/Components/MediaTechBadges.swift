import SwiftUI
import CoreTorrent
import DesignSystem

enum MediaTechKind: Hashable {
    case fourK
    case hdr
    case dolbyVision
    case dolbyAtmos
}

enum MediaTechBadgeContext {
    /// Hero on the backdrop.
    case hero
    /// Lists and cards — same image assets as hero.
    case surface
}

enum MediaTechBadgeSize {
    case regular
    case list
}

struct MediaTechBadgeRow: View {
    let kinds: [MediaTechKind]
    var context: MediaTechBadgeContext = .hero
    var size: MediaTechBadgeSize = .regular

    var body: some View {
        HStack(spacing: size == .list ? 4 : (context == .hero ? 6 : 4)) {
            ForEach(kinds, id: \.self) { kind in
                MediaTechBadge(kind: kind, context: context, size: size)
            }
        }
    }
}

struct MediaTechBadge: View {
    let kind: MediaTechKind
    var context: MediaTechBadgeContext = .hero
    var size: MediaTechBadgeSize = .regular

    private var isDolby: Bool {
        kind == .dolbyAtmos || kind == .dolbyVision
    }

    var body: some View {
        if let assetName = kind.assetName {
            if isDolby {
                dolbyPillBadge(assetName: assetName)
            } else {
                // 4K / HDR — template mask only (same tone as 1080p in How to Watch).
                Image(assetName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .frame(width: kind.displayWidth(for: size), height: kind.displayHeight(for: size))
                    .accessibilityLabel(kind.accessibilityLabel)
            }
        } else {
            MediaFilledBadge(kind.fallbackLabel)
        }
    }

    /// Dolby lockups: template on dark pill; Vision uses 372×138 vertical art (not the legacy stacked mark).
    private func dolbyPillBadge(assetName: String) -> some View {
        let overallWidth = kind.displayWidth(for: size)
        let overallHeight = kind.displayHeight(for: size)
        let horizontalPadding: CGFloat = kind == .dolbyVision ? 4 : (size == .list ? 3.5 * 1.05 : 3.5)
        let verticalPadding: CGFloat = kind == .dolbyVision ? 3 : (size == .list ? 2.0 * 1.05 : 2.0)

        return Image(assetName)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(.white)
            .frame(width: overallWidth - horizontalPadding * 2, height: overallHeight - verticalPadding * 2)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.black.opacity(0.55))
            )
            .frame(width: overallWidth, height: overallHeight)
            .accessibilityLabel(kind.accessibilityLabel)
    }
}

private extension MediaTechKind {
    var assetName: String? {
        switch self {
        case .fourK: "badge-4k"
        case .hdr: "badge-hdr"
        case .dolbyVision: "badge-dolby-vision"
        case .dolbyAtmos: "badge-dolby-atmos"
        }
    }

    /// `badge-dolby-vision.png` source artboard (CloudFront vertical lockup).
    static let dolbyVisionAspectRatio: CGFloat = 372.0 / 138.0

    func displayHeight(for size: MediaTechBadgeSize) -> CGFloat {
        let base: CGFloat = switch self {
        case .fourK: 13
        case .hdr: 13
        case .dolbyVision: 18
        case .dolbyAtmos: 15
        }
        return size == .list ? base * 1.05 : base
    }

    func displayWidth(for size: MediaTechBadgeSize) -> CGFloat {
        let height = displayHeight(for: size)
        switch self {
        case .dolbyVision:
            return height * Self.dolbyVisionAspectRatio
        case .fourK:
            return size == .list ? 25 * 1.05 : 25
        case .hdr:
            return size == .list ? 30 * 1.05 : 30
        case .dolbyAtmos:
            return size == .list ? 34 * 1.05 : 34
        }
    }

    var fallbackLabel: String {
        switch self {
        case .fourK: "4K"
        case .hdr: "HDR"
        case .dolbyVision: "Dolby Vision"
        case .dolbyAtmos: "Dolby Atmos"
        }
    }

    var accessibilityLabel: String { fallbackLabel }
}

func torrentTechKinds(for torrent: TorrentResult) -> [MediaTechKind] {
    var kinds: [MediaTechKind] = []
    if torrent.quality == .p2160 {
        kinds.append(.fourK)
    }
    if torrent.hdrType == .dolbyVisionOnly || torrent.hdrType == .dolbyVisionWithHDR10 {
        kinds.append(.dolbyVision)
    } else if torrent.hdrType == .hdr10Plus || torrent.hdrType == .hdr10 || torrent.hdrType == .hdr {
        kinds.append(.hdr)
    }
    if torrent.audioFormat == .dolbyAtmos {
        kinds.append(.dolbyAtmos)
    }
    return kinds
}

/// Maps persisted download quality/HDR strings to hero/list tech badges.
func downloadTechKinds(quality: String, hdrType: String?) -> [MediaTechKind] {
    var kinds: [MediaTechKind] = []
    if quality == VideoQuality.p2160.rawValue {
        kinds.append(.fourK)
    }
    if let hdrType, let parsed = HDRType(rawValue: hdrType) {
        switch parsed {
        case .dolbyVisionOnly, .dolbyVisionWithHDR10:
            kinds.append(.dolbyVision)
        case .hdr10Plus, .hdr10, .hdr:
            kinds.append(.hdr)
        case .hlg:
            break
        }
    }
    return kinds
}

func detailTechKinds(from torrents: [TorrentResult]) -> [MediaTechKind] {
    var kinds: [MediaTechKind] = []
    if torrents.contains(where: { $0.quality == .p2160 }) {
        kinds.append(.fourK)
    }
    if torrents.contains(where: {
        $0.hdrType == .dolbyVisionOnly || $0.hdrType == .dolbyVisionWithHDR10
    }) {
        kinds.append(.dolbyVision)
    } else if torrents.contains(where: { $0.hdrType == .hdr10Plus || $0.hdrType == .hdr10 || $0.hdrType == .hdr }) {
        kinds.append(.hdr)
    }
    if torrents.contains(where: { $0.audioFormat == .dolbyAtmos }) {
        kinds.append(.dolbyAtmos)
    }
    return kinds
}
