import SwiftUI
import CoreMetadata
import CoreStorage
import SwiftData

struct AsyncLogoView: View {
    let movieId: Int
    let title: String
    
    @State private var logoURL: URL?
    @State private var loadFailed = false
    @Query private var settings: [AppSettings]
    
    var body: some View {
        Group {
            if let url = logoURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 160, alignment: .bottomLeading)
                            .shadow(color: .black.opacity(0.6), radius: 10, x: 0, y: 5)
                    } else if phase.error != nil {
                        fallbackTitle
                    } else {
                        ProgressView().frame(height: 160)
                    }
                }
            } else if loadFailed {
                fallbackTitle
            } else {
                ProgressView().frame(height: 160)
            }
        }
        .task(id: movieId) {
            guard let mode = resolveMetadataMode(from: settings) else {
                loadFailed = true
                return
            }
            do {
                let client = MetadataClient(mode: mode)
                // Timeout after 2 seconds
                let path = try await withThrowingTaskGroup(of: String?.self) { group in
                    group.addTask {
                        try await client.movieLogoPath(id: movieId)
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                    group.cancelAll()
                    return try await group.next() ?? nil
                }
                if let path = path {
                    logoURL = client.imageURL(path: path, width: 1000)
                } else {
                    loadFailed = true
                }
            } catch {
                loadFailed = true
            }
        }
    }
    
    private var fallbackTitle: some View {
        Text(title)
            .font(.system(size: 24, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 10, x: 0, y: 5)
            .frame(maxHeight: 160, alignment: .bottomLeading)
            .lineLimit(2)
    }
}
