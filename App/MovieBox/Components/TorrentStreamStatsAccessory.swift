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
            TorrentStreamStatsPopover(snapshot: snapshot)
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

private struct TorrentStreamStatsPopover: View {
    let snapshot: StreamDiagnosticsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stream Stats")
                        .font(.headline)
                    Text("Updated \(snapshot.updatedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if snapshot.sections.isEmpty {
                        ContentUnavailableView(
                            "No stream data",
                            systemImage: "antenna.radiowaves.left.and.right.slash",
                            description: Text("Stats appear while a torrent is streaming.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        ForEach(snapshot.sections) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.title.uppercased())
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                VStack(spacing: 0) {
                                    ForEach(section.rows) { row in
                                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                                            Text(row.label)
                                                .foregroundStyle(.secondary)
                                                .frame(width: 148, alignment: .leading)
                                            Text(row.value)
                                                .font(.system(.caption, design: .monospaced))
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(.vertical, 5)
                                        if row.id != section.rows.last?.id {
                                            Divider().opacity(0.35)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 520)
    }
}
