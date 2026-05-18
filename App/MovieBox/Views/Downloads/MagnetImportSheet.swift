import SwiftUI

struct MagnetImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var magnetInput: String
    let isStreaming: Bool
    @Binding var errorMessage: String?
    let onStream: () -> Void
    let onDownload: () -> Void
    let onOpenTorrentFile: () -> Void

    private var hasInput: Bool {
        !magnetInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Open torrent", systemImage: "link.circle.fill")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text("Paste a magnet link, info hash, stream URL, or choose a .torrent file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("magnet:?xt=… or 40-char info hash", text: $magnetInput, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            Button {
                onOpenTorrentFile()
            } label: {
                Label("Choose .torrent file…", systemImage: "doc.badge.arrow.down")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if hasInput {
                    Button {
                        magnetInput = ""
                        errorMessage = nil
                    } label: {
                        Text("Clear")
                    }

                    Button {
                        onDownload()
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onStream()
                    } label: {
                        Label(isStreaming ? "Preparing…" : "Stream", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isStreaming)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
