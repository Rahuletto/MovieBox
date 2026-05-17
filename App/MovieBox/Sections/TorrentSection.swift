import AppKit
import SwiftUI
import CoreStorage
import CoreStreaming
import CoreMetadata
import CoreTorrent
import DesignSystem
import CorePlayer

struct TorrentSection: View {
    @Environment(PlayerState.self) private var playerState

    let movie: Movie
    let torrents: [TorrentResult]
    let searchDiagnostics: TorrentSearchDiagnostics?
    let isTV: Bool
    let orchestrator: StreamingOrchestrator
    let subtitleURL: URL?
    var subtitleAppearance: SubtitleAppearance = .cinematic

    @StateObject private var downloadManager = DownloadManager()
    @State private var showUnseeded = false
    @State private var visibleLimit = 24
    @State private var busyTorrentID: UUID?
    @State private var cardErrors: [UUID: String] = [:]
    @State private var errorDismissTasks: [UUID: Task<Void, Never>] = [:]
    @State private var streamSession: StreamSession?
    @State private var playbackCoordinator: TorrentPlaybackCoordinator?
    @State private var downloadWatchTask: Task<Void, Never>?

    private let pageSize = 24
    private let gridColumns = [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 10)]

    private var seededTorrents: [TorrentResult] { torrents.filter { $0.seeders > 0 } }
    private var unseededTorrents: [TorrentResult] { torrents.filter { $0.seeders <= 0 } }
    private var displayedTorrents: [TorrentResult] {
        if showUnseeded || seededTorrents.isEmpty { return torrents }
        return seededTorrents
    }

    private var visibleTorrents: [TorrentResult] {
        Array(displayedTorrents.prefix(visibleLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if torrents.isEmpty {
                ContentUnavailableView(
                    "No Versions Found",
                    systemImage: "magnifyingglass",
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                if seededTorrents.isEmpty && !unseededTorrents.isEmpty {
                    Text("No seeded releases right now. Unseeded copies may not stream.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 10) {
                    ForEach(visibleTorrents) { torrent in
                        TorrentVersionCard(
                            model: TorrentCardModel(torrent: torrent),
                            isBusy: busyTorrentID == torrent.id,
                            errorMessage: cardErrors[torrent.id],
                            onStream: { startStream(torrent) },
                            onDownload: { startDownload(torrent) },
                            onCopyError: { copyError(for: torrent.id) }
                        )
                    }
                }

                footerControls
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Available Versions")
                .font(MovieBoxTypography.title)
            Spacer()
            if !displayedTorrents.isEmpty {
                Text("\(displayedTorrents.count) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var footerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if visibleLimit < displayedTorrents.count {
                Button("Show \(min(pageSize, displayedTorrents.count - visibleLimit)) more") {
                    visibleLimit = min(visibleLimit + pageSize, displayedTorrents.count)
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            }

            if !unseededTorrents.isEmpty {
                Button {
                    showUnseeded.toggle()
                    visibleLimit = pageSize
                } label: {
                    Label(
                        showUnseeded
                            ? "Show seeded only"
                            : "View all (\(unseededTorrents.count) unseeded)",
                        systemImage: showUnseeded ? "chevron.up" : "chevron.down"
                    )
                    .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    private var emptyDescription: String {
        let diagnostics = searchDiagnostics ?? TorrentSearchDiagnostics()
        return diagnostics.emptyListingMessage(title: movie.title, isTV: isTV)
    }

    // MARK: - Actions (single shared session / download manager)

    private func startStream(_ torrent: TorrentResult) {
        busyTorrentID = torrent.id
        clearError(for: torrent.id)

        let coordinator = TorrentPlaybackCoordinator(orchestrator: orchestrator)
        playbackCoordinator = coordinator
        let session = coordinator.beginStream(torrent: torrent)
        streamSession = session

        Task {
            while !Task.isCancelled {
                if case .ready = session.state { break }
                if case .failed = session.state { break }
                try? await Task.sleep(for: .milliseconds(300))
            }

            await MainActor.run {
                busyTorrentID = nil

                if case .failed(let message) = session.state {
                    presentError(message, for: torrent.id)
                    return
                }

                guard case .ready = session.state else {
                    presentError("Stream did not become ready.", for: torrent.id)
                    return
                }

                do {
                    try coordinator.finishPlayback(
                        torrent: torrent,
                        allTorrents: torrents,
                        session: session,
                        playerState: playerState,
                        movieId: movie.id,
                        subtitleURL: subtitleURL,
                        subtitleAppearance: subtitleAppearance
                    )
                } catch {
                    presentError(error.localizedDescription, for: torrent.id)
                }
            }
        }
    }

    private func startDownload(_ torrent: TorrentResult) {
        busyTorrentID = torrent.id
        clearError(for: torrent.id)

        let taskId = downloadManager.startDownload(
            tmdbId: movie.id,
            title: torrent.title,
            magnetURI: torrent.magnetURI,
            quality: torrent.quality.rawValue,
            hdrType: torrent.hdrType?.rawValue
        )

        downloadWatchTask?.cancel()
        downloadWatchTask = Task {
            await watchDownload(taskId: taskId, torrentID: torrent.id)
        }
    }

    private func watchDownload(taskId: UUID, torrentID: UUID) async {
        while !Task.isCancelled, busyTorrentID == torrentID {
            guard let task = downloadManager.tasks.first(where: { $0.id == taskId }) else {
                await MainActor.run { busyTorrentID = nil }
                return
            }
            switch task.state {
            case .downloading where task.totalBytes > 0:
                await MainActor.run { busyTorrentID = nil }
                return
            case .completed, .paused:
                await MainActor.run { busyTorrentID = nil }
                return
            case .failed:
                await MainActor.run {
                    busyTorrentID = nil
                    presentError("Download failed for this release.", for: torrentID)
                }
                return
            case .downloading, .queued:
                break
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func presentError(_ message: String, for id: UUID) {
        errorDismissTasks[id]?.cancel()
        cardErrors[id] = message
        errorDismissTasks[id] = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                cardErrors.removeValue(forKey: id)
                errorDismissTasks.removeValue(forKey: id)
            }
        }
    }

    private func clearError(for id: UUID) {
        errorDismissTasks[id]?.cancel()
        errorDismissTasks.removeValue(forKey: id)
        cardErrors.removeValue(forKey: id)
    }

    private func copyError(for id: UUID) {
        guard let message = cardErrors[id] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
    }
}

// MARK: - Lightweight display model (computed once per torrent)

private struct TorrentCardModel: Identifiable, Hashable {
    let id: UUID
    let source: String
    let quality: String
    let qualityColor: Color
    let title: String
    let detailLine: String
    let seeders: Int
    let leechers: Int

    init(torrent: TorrentResult) {
        id = torrent.id
        source = torrent.trackerSource.label
        quality = torrent.quality.rawValue
        qualityColor = switch torrent.quality {
        case .p2160: Color.purple
        case .p1080: Color.blue
        case .p720: Color.teal
        }
        title = torrent.title

        var parts: [String] = []
        if torrent.sizeBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: torrent.sizeBytes, countStyle: .file))
        }
        parts.append(torrent.codec.rawValue)
        parts.append(torrent.source.rawValue)
        if let hdr = torrent.hdrType { parts.append(hdr.rawValue) }
        if let audio = torrent.audioFormat { parts.append(audio.rawValue) }
        detailLine = parts.joined(separator: " · ")

        seeders = torrent.seeders
        leechers = torrent.leechers
    }
}

// MARK: - Flat card (no glass, no blur)

private struct TorrentVersionCard: View, Equatable {
    let model: TorrentCardModel
    let isBusy: Bool
    let errorMessage: String?
    let onStream: () -> Void
    let onDownload: () -> Void
    let onCopyError: () -> Void

    static func == (lhs: TorrentVersionCard, rhs: TorrentVersionCard) -> Bool {
        lhs.model == rhs.model
            && lhs.isBusy == rhs.isBusy
            && lhs.errorMessage == rhs.errorMessage
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(model.source)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(model.quality)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(model.qualityColor)
                }

                Text(model.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !model.detailLine.isEmpty {
                    Text(model.detailLine)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                HStack(spacing: 12) {
                    Label("\(model.seeders)", systemImage: "arrow.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BadgePalette.seedColor(model.seeders))
                    if model.leechers > 0 {
                        Label("\(model.leechers)", systemImage: "arrow.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Button("Stream", action: onStream)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Download", action: onDownload)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .disabled(isBusy)
            }
            .padding(12)
            .opacity(isBusy ? 0.35 : 1)

            if isBusy {
                ProgressView()
                    .controlSize(.regular)
            }

            if let errorMessage {
                VStack {
                    Spacer()
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption2)
                        Text(errorMessage)
                            .font(.caption2)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(action: onCopyError) {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .padding(8)
                }
            }
        }
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}
