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
    let orchestrator: StreamingOrchestrator
    let subtitleURL: URL?
    let downloadManager: DownloadManager
    @Environment(PlayerState.self) private var playerState
    @State private var streamSession: StreamSession?
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
        let session = StreamSession(orchestrator: orchestrator)
        streamSession = session

        Task {
            await session.start(torrent: result)

            if case .ready(let url) = session.state {
                let playerHdr: PlayerHDRType? = {
                    guard let type = result.hdrType else { return nil }
                    switch type {
                    case .hdr: return .hdr
                    case .hdr10: return .hdr10
                    case .hdr10Plus: return .hdr10Plus
                    case .dolbyVisionOnly: return .dolbyVision
                    case .dolbyVisionWithHDR10: return .dolbyVisionWithHDR10
                    case .hlg: return .hdr
                    }
                }()
                playerState.load(
                    url: url,
                    title: result.title,
                    movieId: movieId,
                    subtitleURL: subtitleURL,
                    hdrType: playerHdr
                )
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
