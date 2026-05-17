import SwiftUI
import CoreStreaming
import CoreMetadata
import CoreTorrent
import DesignSystem
import CorePlayer

struct TorrentSection: View {
    let movie: Movie
    let torrents: [TorrentResult]
    let orchestrator: StreamingOrchestrator
    let subtitleURL: URL?
    @Environment(PlayerState.self) private var playerState
    @StateObject private var downloadManager = DownloadManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Available Versions")
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)

            if torrents.isEmpty {
                ContentUnavailableView(
                    "No Versions Found",
                    systemImage: "magnifyingglass",
                    description: Text("YTS did not return torrent results for \(movie.title).")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(torrents) { torrent in
                        TorrentResultRow(
                            movieId: movie.id,
                            result: torrent,
                            allTorrents: torrents,
                            orchestrator: orchestrator,
                            subtitleURL: subtitleURL,
                            downloadManager: downloadManager
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct TorrentResultRow: View {
    let movieId: Int
    let result: TorrentResult
    let allTorrents: [TorrentResult]
    let orchestrator: StreamingOrchestrator
    let subtitleURL: URL?
    let downloadManager: DownloadManager
    @Environment(PlayerState.self) private var playerState
    @State private var streamSession: StreamSession?
    @State private var playbackCoordinator: TorrentPlaybackCoordinator?
    @State private var isStreaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        GlassBadge(result.quality.rawValue)
                        if let hdr = result.hdrType {
                            GlassBadge(hdr.rawValue, color: BadgePalette.hdrColor(label: hdr.rawValue))
                        }
                        if let audio = result.audioFormat {
                            GlassBadge(audio.rawValue, color: .blue)
                        }
                        GlassBadge(result.codec.rawValue)
                        GlassBadge(result.source.rawValue)
                    }
                    HStack(spacing: 14) {
                        Text("\(result.seeders) seeders")
                            .foregroundStyle(BadgePalette.seedColor(result.seeders))
                        Text("\(result.leechers) leechers")
                        Text(result.trackerSource.label)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()

                if isStreaming, let session = streamSession {
                    StreamProgressView(session: session)
                } else {
                    HStack(spacing: 8) {
                        Button("Stream", action: startStream)
                        Button("Download", action: startDownload)
                    }
                }
            }
        }
        .padding(16)
        .adaptiveGlass(cornerRadius: 18)
    }

    private func startStream() {
        isStreaming = true
        let coordinator = TorrentPlaybackCoordinator(orchestrator: orchestrator)
        playbackCoordinator = coordinator
        let session = coordinator.beginStream(torrent: result)
        streamSession = session

        Task {
            while !Task.isCancelled {
                if case .ready = session.state { break }
                if case .failed = session.state { break }
                try? await Task.sleep(for: .milliseconds(250))
            }

            await MainActor.run {
                isStreaming = false
                do {
                    try coordinator.finishPlayback(
                        torrent: result,
                        allTorrents: allTorrents,
                        session: session,
                        playerState: playerState,
                        movieId: movieId,
                        subtitleURL: subtitleURL
                    )
                } catch {
                    // Row-level failure: player overlay will show if partially loaded
                }
            }
        }
    }

    private func startDownload() {
        downloadManager.startDownload(
            tmdbId: movieId,
            title: result.title,
            magnetURI: result.magnetURI,
            quality: result.quality.rawValue,
            hdrType: result.hdrType?.rawValue
        )
    }
}

private struct StreamProgressView: View {
    @ObservedObject var session: StreamSession

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            switch session.state {
            case .preparing:
                ProgressView()
                    .controlSize(.small)
                Text("Preparing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .buffering(let progress):
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                HStack(spacing: 8) {
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                    if session.downloadSpeed > 0 {
                        Text(formatSpeed(session.downloadSpeed))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if session.bufferedPieces > 0 {
                        Text("(\(session.bufferedPieces) pieces)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

            case .ready:
                Label("Streaming", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)

            case .failed(let error):
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)

            case .cancelled:
                Text("Cancelled")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .idle:
                EmptyView()
            }
        }
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        } else if bytesPerSecond >= 1000 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}
