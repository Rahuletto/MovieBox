import SwiftUI
import DesignSystem

/// Navigation bar with back (left) and optional share (right).
struct NavigationHeader: View {
    let title: String?
    let shareURL: URL?
    let shareTitle: String?
    let onBack: () -> Void

    init(
        title: String?,
        shareURL: URL? = nil,
        shareTitle: String? = nil,
        onBack: @escaping () -> Void
    ) {
        self.title = title
        self.shareURL = shareURL
        self.shareTitle = shareTitle
        self.onBack = onBack
    }

    var body: some View {
        HStack(spacing: 12) {
            BackButton(action: onBack, title: title)
            Spacer(minLength: 0)
            if let shareURL {
                ShareLink(
                    item: shareURL,
                    subject: Text(shareTitle ?? ""),
                    message: Text(shareTitle ?? "")
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .adaptiveGlass(cornerRadius: 32)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
                .help("Share")
            }
        }
        .padding(.leading, 96)
        .padding(.trailing, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

}
