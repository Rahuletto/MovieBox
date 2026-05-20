import CoreTorrent
import DesignSystem
import MovieBoxCore
import SwiftUI

// MARK: - Display model

struct TorrentCardModel: Identifiable, Hashable {
    let id: UUID
    let source: String
    let quality: String
    let techKinds: [MediaTechKind]
    let title: String
    let detailLine: String
    let seeders: Int
    let leechers: Int

    init(torrent: TorrentResult) {
        id = torrent.id
        source = torrent.trackerSource.label
        quality = torrent.quality.rawValue
        techKinds = torrentTechKinds(for: torrent)
        title = torrent.title

        var parts: [String] = []
        if torrent.sizeBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: torrent.sizeBytes, countStyle: .file))
        }
        parts.append(torrent.codec.rawValue)
        if torrent.source != .unknown {
            parts.append(torrent.source.rawValue)
        }
        detailLine = parts.joined(separator: " · ")

        seeders = torrent.seeders
        leechers = torrent.leechers
    }
}

// MARK: - List

enum TorrentVersionListMode: Equatable {
    case detail(
        busyTorrentID: UUID?,
        bufferingByID: [UUID: TorrentRowBufferingSnapshot],
        cardErrors: [UUID: String],
        onStream: (UUID) -> Void,
        onDownload: (UUID) -> Void,
        onCopyError: (UUID) -> Void
    )
    case player(
        selectedTorrentID: UUID?,
        isSwitching: Bool,
        onSelect: (UUID) -> Void
    )

    static func == (lhs: TorrentVersionListMode, rhs: TorrentVersionListMode) -> Bool {
        switch (lhs, rhs) {
        case let (.detail(lBusy, lBuf, lErr, _, _, _), .detail(rBusy, rBuf, rErr, _, _, _)):
            lBusy == rBusy && lBuf == rBuf && lErr == rErr
        case let (.player(lSel, lSw, _), .player(rSel, rSw, _)):
            lSel == rSel && lSw == rSw
        default:
            false
        }
    }
}

struct TorrentVersionSectionGroup: Identifiable {
    let id: String
    let title: String
    let models: [TorrentCardModel]
}

struct TorrentVersionGroupedList: View {
    let sections: [TorrentVersionSectionGroup]
    let mode: TorrentVersionListMode
    var sectionHeaderColor: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(sectionHeaderColor)
                        .textCase(.uppercase)
                        .padding(.horizontal, 4)

                    TorrentVersionList(models: section.models, mode: mode)
                }
            }
        }
    }
}

struct TorrentVersionList: View {
    let models: [TorrentCardModel]
    let mode: TorrentVersionListMode

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                TorrentVersionRow(
                    model: model,
                    mode: mode,
                    rowIndex: index,
                    rowCount: models.count
                )
                .equatable()

                if index < models.count - 1 {
                    Divider()
                        .padding(.leading, 12)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}

// MARK: - Row

struct TorrentVersionRow: View, Equatable {
    let model: TorrentCardModel
    let mode: TorrentVersionListMode
    let rowIndex: Int
    let rowCount: Int

    @State private var isHovering = false

    private static let listCornerRadius: CGFloat = 12

    static func == (lhs: TorrentVersionRow, rhs: TorrentVersionRow) -> Bool {
        lhs.model == rhs.model
            && lhs.rowIndex == rhs.rowIndex
            && lhs.rowCount == rhs.rowCount
            && lhs.modeKey == rhs.modeKey
    }

    private var modeKey: String {
        switch mode {
        case .detail(let busy, let buffering, let errors, _, _, _):
            let buf = buffering[model.id].map { "\($0.progress)-\($0.phase)" } ?? ""
            return "detail-\(busy?.uuidString ?? "")-\(buf)-\(errors[model.id] ?? "")"
        case .player(let selected, let switching, _):
            return "player-\(selected?.uuidString ?? "")-\(switching)"
        }
    }

    var body: some View {
        Group {
            switch mode {
            case .player(let selectedID, let isSwitching, let onSelect):
                playerRow(selectedID: selectedID, isSwitching: isSwitching, onSelect: onSelect)
            case .detail(let busyID, let buffering, let errors, let onStream, let onDownload, let onCopyError):
                detailRow(
                    busyID: busyID,
                    buffering: buffering[model.id],
                    errorMessage: errors[model.id],
                    onStream: { onStream(model.id) },
                    onDownload: { onDownload(model.id) },
                    onCopyError: { onCopyError(model.id) }
                )
            }
        }
    }

    private func playerRow(selectedID: UUID?, isSwitching: Bool, onSelect: @escaping (UUID) -> Void) -> some View {
        let isSelected = selectedID == model.id
        return Button {
            guard !isSelected, !isSwitching else { return }
            onSelect(model.id)
        } label: {
            rowContent(
                trailing: {
                    if isSwitching && isSelected {
                        ProgressView()
                            .controlSize(.small)
                    } else if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.green)
                    }
                },
                errorMessage: nil
            )
        }
        .buttonStyle(.plain)
        .disabled(isSwitching)
    }

    private func detailRow(
        busyID: UUID?,
        buffering: TorrentRowBufferingSnapshot?,
        errorMessage: String?,
        onStream: @escaping () -> Void,
        onDownload: @escaping () -> Void,
        onCopyError: @escaping () -> Void
    ) -> some View {
        let isBusy = busyID == model.id
        return rowContent(
            buffering: isBusy ? buffering : nil,
            trailing: {
                HStack(spacing: 4) {
                    Button(action: onStream) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 22))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Play")

                    Button(action: onDownload) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 22))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Download")
                }
                .frame(width: 64, alignment: .trailing)
                .opacity(isBusy ? 0.35 : 1)
                .overlay {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .disabled(isBusy)
            },
            errorMessage: errorMessage,
            onCopyError: onCopyError
        )
    }

    private func rowContent<Trailing: View>(
        buffering: TorrentRowBufferingSnapshot? = nil,
        @ViewBuilder trailing: () -> Trailing,
        errorMessage: String?,
        onCopyError: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    resolutionBadge
                    if !model.techKinds.isEmpty {
                        MediaTechBadgeRow(kinds: model.techKinds, context: .hero, size: .list)
                    }
                    if let buffering {
                        Text("\(Int(buffering.progress * 100))%")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                }

                Text(model.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                metadataRow

                if let buffering {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(buffering.phase)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        if !buffering.detail.isEmpty {
                            Text(buffering.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                if let errorMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                        if let onCopyError {
                            Button("Copy", action: onCopyError)
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if let buffering {
                GeometryReader { proxy in
                    let width = max(0, proxy.size.width * buffering.progress)
                    Color.white.opacity(0.14)
                        .frame(width: width, height: proxy.size.height)
                        .clipShape(progressLeadingShape(in: proxy.size))
                }
                .animation(.easeInOut(duration: 0.25), value: buffering.progress)
            }
        }
        .contentShape(Rectangle())
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private func progressLeadingShape(in size: CGSize) -> UnevenRoundedRectangle {
        let r = Self.listCornerRadius
        let isFirst = rowIndex == 0
        let isLast = rowIndex == rowCount - 1
        let isOnly = rowCount == 1
        return UnevenRoundedRectangle(
            topLeadingRadius: isFirst || isOnly ? r : 0,
            bottomLeadingRadius: isLast || isOnly ? r : 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    private var metadataRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.detailLine.isEmpty {
                Text(model.detailLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(BadgePalette.seedColor(model.seeders))
                    Text("\(model.seeders)")
                        .monospacedDigit()
                        .foregroundStyle(BadgePalette.seedColor(model.seeders))
                }

                if model.leechers > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.secondary)
                        Text("\(model.leechers)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Text(model.source)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .font(.caption)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var resolutionBadge: some View {
        if model.quality != VideoQuality.p2160.rawValue {
            Text(model.quality)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}
