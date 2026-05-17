import SwiftUI
import CoreMetadata
import CoreStorage
import SwiftData

struct AsyncLogoView: View {
    let movieId: Int
    let title: String
    let kind: MediaKind
    
    @State private var logoURL: URL?
    @State private var loadFailed = false
    @Query private var settings: [AppSettings]
    
    var body: some View {
        Group {
            if let url = logoURL {
                CachedImageView(url: url) {
                    ProgressView().frame(height: 100)
                } content: { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 100, alignment: .bottomLeading)
//                        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 5)
                }
            } else if loadFailed {
                fallbackTitle
            } else {
                ProgressView().frame(height: 100)
            }
        }
        .task(id: "\(movieId)-\(kind.rawValue)") {
            logoURL = nil
            loadFailed = false

            guard let mode = resolveMetadataMode(from: settings) else {
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
            .font(.system(size: 38, weight: .bold))
            .foregroundStyle(.primary)
//            .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 5)
            .frame(maxHeight: 160, alignment: .bottomLeading)
            .lineLimit(2)
    }
}
