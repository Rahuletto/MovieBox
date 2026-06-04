import SwiftUI
import CoreMetadata
import MovieBoxCore
import CoreStorage
import SwiftData

struct AsyncLogoView: View {
    let movieId: Int
    let title: String
    let kind: MediaKind
    var maxLogoHeight: CGFloat = 100
    var fallbackTitleSize: CGFloat = 38
    /// When false, the logo hugs the leading edge instead of spanning the card width.
    var fillsAvailableWidth: Bool = true

    @State private var logoURL: URL?
    @State private var loadFailed = false
    @Query private var settings: [AppSettings]
    
    var body: some View {
        Group {
            if let url = logoURL {
                CachedImageView(url: url) {
                    ProgressView().frame(height: maxLogoHeight)
                } content: { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(
                            maxWidth: fillsAvailableWidth ? .infinity : nil,
                            maxHeight: maxLogoHeight,
                            alignment: .bottomLeading
                        )
                }
            } else if loadFailed {
                fallbackTitle
            } else {
                ProgressView().frame(height: maxLogoHeight)
            }
        }
        .frame(
            maxWidth: fillsAvailableWidth ? .infinity : nil,
            maxHeight: maxLogoHeight,
            alignment: .bottomLeading
        )
        .task(id: "\(movieId)-\(kind.rawValue)") {
            logoURL = nil
            loadFailed = false

            guard let mode = MetadataSettings.mode(from: settings) else {
                loadFailed = true
                return
            }
            do {
                let client = MetadataClient(mode: mode)
                if let url = try await client.movieLogoURL(id: movieId, kind: kind) {
                    // Make sure the result still belongs to the current slide —
                    // a fast user can advance the carousel before the await returns.
                    guard !Task.isCancelled else { return }
                    logoURL = url
                } else {
                    guard !Task.isCancelled else { return }
                    loadFailed = true
                }
            } catch {
                guard !Task.isCancelled else { return }
                loadFailed = true
            }
        }
    }
    
    private var fallbackTitle: some View {
        // `.primary` adapts to color scheme (white in dark, black in light),
        // matching the hero carousel's color-scheme-aware fade.
        Text(title)
            .font(.system(size: fallbackTitleSize, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 3)
            .frame(maxHeight: maxLogoHeight + 24, alignment: .bottomLeading)
            .lineLimit(2)
    }
}
