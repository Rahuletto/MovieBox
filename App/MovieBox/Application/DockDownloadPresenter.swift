import AppKit
import CoreStorage
import CoreStreaming
import Foundation

/// macOS Dock download bar (same approach as system/Launchpad: icon + bar overlay on `dockTile`).
///
/// `Progress.publish()` alone does not reliably show a Dock bar on current macOS releases.
@MainActor
enum DockDownloadPresenter {
    private static let tileSize: CGFloat = 128
    private static var tileView = DockTileOverlayView(
        frame: NSRect(x: 0, y: 0, width: tileSize, height: tileSize)
    )

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

        tileView.progress = max(fraction, active.contains(where: { $0.state == .queued }) ? 0.04 : 0)
        tileView.needsDisplay = true

        let dockTile = NSApplication.shared.dockTile
        dockTile.contentView = tileView
        dockTile.badgeLabel = active.count > 1 ? "\(active.count)" : nil
        dockTile.display()
    }

    static func clear() {
        tileView.progress = 0
        let dockTile = NSApplication.shared.dockTile
        dockTile.contentView = nil
        dockTile.badgeLabel = nil
        dockTile.display()
    }
}

/// Draws the unmodified app icon, then the standard white/black Dock progress bar on top.
private final class DockTileOverlayView: NSView {
    var progress: Double = 0

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high

        if let icon = NSApplication.shared.applicationIconImage {
            icon.draw(in: bounds)
        }

        guard progress > 0.001 else { return }

        let barInset: CGFloat = 8
        let barHeight: CGFloat = 10
        // Match Launchpad-style placement (near bottom of tile; AppKit origin is bottom-left).
        let barRect = NSRect(
            x: barInset,
            y: 8,
            width: bounds.width - (barInset * 2),
            height: barHeight
        )

        let outer = NSBezierPath(roundedRect: barRect, xRadius: 5, yRadius: 5)
        NSColor.white.withAlphaComponent(0.8).setFill()
        outer.fill()

        let inner = barRect.insetBy(dx: 0.5, dy: 0.5)
        let innerPath = NSBezierPath(roundedRect: inner, xRadius: 4.5, yRadius: 4.5)
        NSColor.black.withAlphaComponent(0.8).setFill()
        innerPath.fill()

        let clamped = min(1, max(0, progress))
        let fillWidth = max(0, (barRect.width - 2) * clamped)
        guard fillWidth > 0.5 else { return }

        let fillRect = NSRect(
            x: barRect.minX + 1,
            y: barRect.minY + 1,
            width: fillWidth,
            height: barRect.height - 2
        )
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 4, yRadius: 4)
        NSColor.white.setFill()
        fillPath.fill()
    }
}
