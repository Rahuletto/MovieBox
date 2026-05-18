import AppKit
import CorePlayer
import CoreStorage
import CoreStreaming
import DesignSystem
import MovieBoxCore
import SwiftUI

struct DownloadTaskRow: View {
    @Environment(PlayerState.self) private var playerState
    let task: DownloadManager.DownloadTask
    let downloadManager: DownloadManager
    let playback: PlaybackSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        GlassBadge(task.quality)
                        if let hdr = task.hdrType {
                            GlassBadge(hdr)
                        }
                        Text(task.state.label)
                            .font(.caption)
                            .foregroundStyle(task.state.color)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(Int(task.progress * 100))%")
                        .font(.headline)
                    if task.speed > 0 {
                        Text(ByteFormatting.speed(task.speed))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ProgressView(value: task.progress)
                .progressViewStyle(.linear)

            HStack(spacing: 8) {
                switch task.state {
                case .downloading:
                    Button("Pause") { downloadManager.pauseDownload(taskId: task.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .paused:
                    Button("Resume") { downloadManager.resumeDownload(taskId: task.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Cancel", role: .destructive) { downloadManager.cancelDownload(taskId: task.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .completed:
                    Button("Watch") {
                        if let path = task.outputPath {
                            playerState.load(
                                url: URL(fileURLWithPath: path),
                                title: task.title,
                                movieId: task.tmdbId,
                                subtitleAppearance: playback.appearance,
                                subtitleFontSize: playback.fontSize
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("Remove") { downloadManager.removeCompleted(taskId: task.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    if let path = task.outputPath {
                        Button("Show in Finder") {
                            let fileURL = URL(fileURLWithPath: path)
                            NSWorkspace.shared.selectFile(
                                fileURL.path,
                                inFileViewerRootedAtPath: fileURL.deletingLastPathComponent().path
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                case .failed:
                    Button("Retry") { downloadManager.cancelDownload(taskId: task.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                default:
                    EmptyView()
                }
            }
        }
        .padding(14)
        .adaptiveGlass(cornerRadius: 14)
    }
}
