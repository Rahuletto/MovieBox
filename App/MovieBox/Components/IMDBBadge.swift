import SwiftUI
import CoreMetadata

/// IMDb rating pill — yellow wordmark on a dark chip (Apple TV–style).
struct IMDBBadge: View {
    let rating: Double
    let enrichment: MovieEnrichment?
    let onTap: (() -> Void)?

    private static let imdbYellow = Color(red: 0.965, green: 0.773, blue: 0.094)

    var body: some View {
        HStack(spacing: 5) {
            Text("IMDb")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(Self.imdbYellow)
            Text(String(format: "%.1f", rating))
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("IMDb rating \(String(format: "%.1f", rating))")
        .onTapGesture {
            onTap?()
        }
    }
}
