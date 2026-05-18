import CoreStorage
import DesignSystem
import SwiftData
import SwiftUI

struct RetryCard: View {
    let message: String
    let retry: () -> Void
    @State private var copied = false
    @Query private var settings: [AppSettings]

    var body: some View {
        VStack(spacing: 16) {
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button(action: retry) {
                    Text("Retry")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.red)
                        .clipShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    DiagnosticsReport.copyToPasteboard(userMessage: message, settings: settings.first)
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                        copied = true
                    }
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                            copied = false
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(copied ? Color.green : Color.primary)
                        Text(copied ? "Copied!" : "Copy Logs")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(copied ? Color.green : Color.primary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.12))
                    .clipShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .adaptiveGlass(cornerRadius: 24)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
