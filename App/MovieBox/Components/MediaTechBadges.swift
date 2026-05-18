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
                let overallWidth = kind.displayWidth(for: size)
                let overallHeight = kind.displayHeight(for: size)
                let horizontalPadding = size == .list ? 3.5 * 1.05 : 3.5
                let verticalPadding = size == .list ? 2.0 * 1.05 : 2.0
                
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: overallWidth - horizontalPadding * 2, height: overallHeight - verticalPadding * 2)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.black.opacity(0.55))
                    )
                    .frame(width: overallWidth, height: overallHeight)
                    .accessibilityLabel(kind.accessibilityLabel)
            } else {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: kind.displayWidth(for: size), height: kind.displayHeight(for: size))
                    .accessibilityLabel(kind.accessibilityLabel)
            }
        } else {
            MediaFilledBadge(kind.fallbackLabel)
        }
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

    func displayHeight(for size: MediaTechBadgeSize) -> CGFloat {
        // Dolby logos are horizontal lockups that read smaller than the
        // simple 4K/HDR pills at the same height, so they need a taller box.
        let base: CGFloat = switch self {
        case .fourK: 13
        case .hdr: 13
        case .dolbyVision: 18
        case .dolbyAtmos: 18
        }
        // List rows want compact badges that visually match the small text
        // resolution chip (~14pt). Hero stays at base size.
        return size == .list ? base * 1.05 : base
    }

    func displayWidth(for size: MediaTechBadgeSize) -> CGFloat {
        let base: CGFloat = switch self {
        case .fourK: 23
        case .hdr: 30
        case .dolbyVision: 48
        case .dolbyAtmos: 42
        }
        return size == .list ? base * 1.05 : base
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
