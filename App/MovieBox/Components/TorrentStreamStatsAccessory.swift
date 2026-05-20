import CorePlayer
import CoreStreaming
import SwiftUI

struct TorrentStreamStatsAccessory: View {
    @ObservedObject var session: TorrentStreamSession
    @State private var isPresented = false
    @State private var snapshot = StreamDiagnosticsSnapshot.empty
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isPresented ? 1.0 : 0.85))
                .frame(width: 30, height: 30)
                .nativeGlassEffect()
        }
        .buttonStyle(.plain)
        .help("Stream stats")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DiagnosticsStatsPopover(snapshot: snapshot.diagnosticsPanel)
                .onAppear { startRefreshing() }
                .onDisappear { stopRefreshing() }
        }
        .onChange(of: isPresented) { _, presented in
            if presented {
                startRefreshing()
            } else {
                stopRefreshing()
            }
        }
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                snapshot = await session.fetchDiagnostics()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}

private extension StreamDiagnosticsSnapshot {
    var diagnosticsPanel: DiagnosticsPanelSnapshot {
        DiagnosticsPanelSnapshot(
            title: "Stream Stats",
            subtitle: "Updated \(updatedAt.formatted(date: .omitted, time: .standard))",
            capturedAt: updatedAt,
            sections: sections.map { section in
                DiagnosticsPanelSnapshot.Section(
                    title: section.title,
                    rows: section.rows.map { row in
                        DiagnosticsPanelSnapshot.Row(label: row.label, value: row.value)
                    }
                )
            },
            emptyTitle: "No stream data",
            emptyDescription: "Stats appear while a torrent is streaming.",
            emptySystemImage: "antenna.radiowaves.left.and.right.slash"
        )
    }
}
