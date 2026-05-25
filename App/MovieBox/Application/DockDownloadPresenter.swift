import AppKit
import CoreStorage
import CoreStreaming
import Foundation

/// macOS-style Dock tile: app icon with a thin horizontal progress bar underneath (like Launchpad downloads).
@MainActor
enum DockDownloadPresenter {
    private static var progressView: DockTileProgressView?
    private static var publishedProgress: Progress?

    static func update(tasks: [DownloadManager.DownloadTask]) {
        let active = tasks.filter { task in
            task.state == .downloading || task.state == .queued
        }

        guard !active.isEmpty else {
            clear()
            return
        }

        let totalUnits = active.reduce(Int64(0)) { $0 + max($1.totalBytes, 1) }
        let completedUnits = active.reduce(Int64(0)) { partial, task in
            let total = max(task.totalBytes, 1)
            if task.state == .queued { return partial }
            return partial + Int64(Double(total) * min(1, max(0, task.progress)))
        }

        let fraction = totalUnits > 0
            ? Double(completedUnits) / Double(totalUnits)
            : 0

        publishFoundationProgress(
            completedUnits: completedUnits,
            totalUnits: totalUnits,
            label: active.count == 1
                ? active[0].title
                : "Downloading \(active.count) items"
        )

        let dockTile = NSApplication.shared.dockTile
        dockTile.badgeLabel = active.count > 1 ? "\(active.count)" : nil

        let view = progressView ?? DockTileProgressView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        progressView = view
        view.progress = fraction
        view.isIndeterminate = fraction <= 0.001 && active.contains(where: { $0.state == .queued })
        dockTile.contentView = view
        dockTile.display()
    }

    static func clear() {
        if let publishedProgress {
            publishedProgress.completedUnitCount = publishedProgress.totalUnitCount
            publishedProgress.cancel()
        }
        publishedProgress = nil
        progressView = nil
        let dockTile = NSApplication.shared.dockTile
        dockTile.contentView = nil
        dockTile.badgeLabel = nil
        dockTile.display()
    }

    private static func publishFoundationProgress(
        completedUnits: Int64,
        totalUnits: Int64,
        label: String
    ) {
        let progress: Progress
        if let existing = publishedProgress, existing.totalUnitCount == max(totalUnits, 1) {
            progress = existing
        } else {
            progress = Progress(totalUnitCount: max(totalUnits, 1))
            progress.kind = .file
            progress.publish()
            progress.becomeCurrent(withPendingUnitCount: 0)
            publishedProgress = progress
        }
        progress.completedUnitCount = min(completedUnits, totalUnits)
        progress.localizedDescription = label
    }
}

private final class DockTileProgressView: NSView {
    var progress: Double = 0
    var isIndeterminate = false

    private enum Metrics {
        static let barHeight: CGFloat = 5
        static let barBottomInset: CGFloat = 11
        static let barHorizontalInset: CGFloat = 15
        static let iconInset: CGFloat = 10
        static let iconGapAboveBar: CGFloat = 7
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let icon = NSApplication.shared.applicationIconImage else { return }

        let barWidth = bounds.width - Metrics.barHorizontalInset * 2
        let barY = bounds.height - Metrics.barBottomInset - Metrics.barHeight
        let iconHeight = max(0, barY - Metrics.iconInset - Metrics.iconGapAboveBar)
        let iconRect = NSRect(
            x: Metrics.iconInset,
            y: Metrics.iconInset,
            width: bounds.width - Metrics.iconInset * 2,
            height: iconHeight
        )
        icon.draw(in: iconRect)

        let barRect = NSRect(
            x: Metrics.barHorizontalInset,
            y: barY,
            width: barWidth,
            height: Metrics.barHeight
        )
        let trackPath = NSBezierPath(
            roundedRect: barRect,
            xRadius: Metrics.barHeight / 2,
            yRadius: Metrics.barHeight / 2
        )
        NSColor(white: 0.32, alpha: 0.95).setFill()
        trackPath.fill()

        let fillFraction: CGFloat
        if isIndeterminate {
            fillFraction = 0.18
        } else {
            fillFraction = CGFloat(min(1, max(0, progress)))
        }

        guard fillFraction > 0.001 else { return }

        let fillWidth = max(Metrics.barHeight, barWidth * fillFraction)
        let fillRect = NSRect(
            x: barRect.minX,
            y: barRect.minY,
            width: fillWidth,
            height: Metrics.barHeight
        )
        let fillPath = NSBezierPath(
            roundedRect: fillRect,
            xRadius: Metrics.barHeight / 2,
            yRadius: Metrics.barHeight / 2
        )
        NSColor(white: 0.9, alpha: 1).setFill()
        fillPath.fill()
    }
}
