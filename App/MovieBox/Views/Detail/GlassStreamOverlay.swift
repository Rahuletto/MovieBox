import CoreStreaming
import MovieBoxCore
import SwiftUI

struct GlassStreamOverlay: View {
    @ObservedObject var session: TorrentStreamSession
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 20) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)

                    Text("Preparing Stream")
                        .font(.headline)
                        .foregroundStyle(.white)

                    switch session.state {
                    case .preparing:
                        Text("Connecting to seeders...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    case .buffering:
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.regular)
                                .tint(.white)

                            Text("Buffering first chunk…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            HStack {
                                if session.bufferedBytes > 0 {
                                    Text(ByteFormatting.buffered(session.bufferedBytes))
                                }
                                Spacer()
                                if session.downloadSpeed > 0 {
                                    Text(ByteFormatting.speed(session.downloadSpeed))
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        }
                    case .ready:
                        Text("Ready to play!")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    case .failed(let error):
                        Text("Failed: \(error)")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    case .cancelled:
                        Text("Cancelled")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    case .idle:
                        EmptyView()
                    }

                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(32)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
            }
        }
    }
}
