import AppKit
import CorePlayer
import CoreStorage
import CoreStreaming
import DesignSystem
import MovieBoxCore
import SwiftUI


struct HDRTestStream: Identifiable {
    let id: String
    let title: String
    let url: String
}

enum DownloadRowModel: Identifiable {
    case task(DownloadManager.DownloadTask)
    case hdrTest(HDRTestStream)

    var id: String {
        switch self {
        case .task(let task):
            task.id.uuidString
        case .hdrTest(let stream):
            stream.id
        }
    }
}

struct DownloadTaskRow: View {
    @Environment(PlayerState.self) private var playerState
    let model: DownloadRowModel
    let downloadManager: DownloadManager
    let playback: PlaybackSettings
    var onWatchHDRTest: ((HDRTestStream) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        ForEach(qualityBadges, id: \.self) { badge in
                            GlassBadge(badge)
                        }
                        Text(statusLabel)
                            .font(.caption)
                            .foregroundStyle(statusColor)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(trailingHeadline)
                        .font(.headline)
                    if let trailingCaption {
                        Text(trailingCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ProgressView(value: progressValue)
                .progressViewStyle(.linear)

            HStack(spacing: 8) {
                actionButtons
            }
        }
        .padding(14)
        .adaptiveGlass(cornerRadius: 14)
    }

    private var title: String {
        switch model {
        case .task(let task):
            task.title
        case .hdrTest(let stream):
            stream.title
        }
    }

    private var qualityBadges: [String] {
        switch model {
        case .task(let task):
            var badges = [task.quality]
            if let hdr = task.hdrType {
                badges.append(hdr)
            }
            return badges
        case .hdrTest:
            return ["4K", "Dolby Vision", "Atmos"]
        }
    }

    private var statusLabel: String {
        switch model {
        case .task(let task):
            task.state.label
        case .hdrTest:
            DownloadState.completed.label
        }
    }

    private var statusColor: Color {
        switch model {
        case .task(let task):
            task.state.color
        case .hdrTest:
            DownloadState.completed.color
        }
    }

    private var trailingHeadline: String {
        switch model {
        case .task(let task):
            "\(Int(task.progress * 100))%"
        case .hdrTest:
            "100%"
        }
    }

    private var trailingCaption: String? {
        switch model {
        case .task(let task):
            task.speed > 0 ? ByteFormatting.speed(task.speed) : nil
        case .hdrTest:
            "HLS"
        }
    }

    private var progressValue: Double {
        switch model {
        case .task(let task):
            task.progress
        case .hdrTest:
            1
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch model {
        case .task(let task):
            taskActionButtons(task)
        case .hdrTest(let stream):
            Button("Watch") {
                onWatchHDRTest?(stream)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func taskActionButtons(_ task: DownloadManager.DownloadTask) -> some View {
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
