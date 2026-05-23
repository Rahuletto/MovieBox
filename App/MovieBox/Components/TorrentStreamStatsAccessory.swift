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
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 15, weight: .semibold))
                .playerGlassSymbol()
                .frame(width: 36, height: 36)
                .playerGlassChrome(.circle, strength: .thick)
        }
        .buttonStyle(.plain)
        .help("Stream stats")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DiagnosticsStatsPopover(snapshot: snapshot.diagnosticsPanel())
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
    func diagnosticsPanel() -> DiagnosticsPanelSnapshot {
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
