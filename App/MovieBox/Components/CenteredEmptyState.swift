import SwiftUI

struct CenteredEmptyState: View {
    let icon: String
    let title: String
    let description: String
    let isLoading: Bool
    var minHeight: CGFloat = 168

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 16) {
                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.secondary)
                        .opacity(0.6)
                }

                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)

            Spacer()
        }
        .frame(height: minHeight)
    }
}
