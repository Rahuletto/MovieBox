import SwiftUI
import DesignSystem
import CoreMetadata
import CoreStorage
import SwiftData

// MARK: - Reusable Hero Section
struct HeroSection: View {
    let backdropPath: String?
    let title: String?
    let logoId: Int?
    let badges: [String]
    let overview: String
    let primaryAction: () -> Void
    let secondaryAction: (() -> Void)?
    let navigationLeft: () -> Void
    let navigationRight: () -> Void
    let movieCount: Int
    let currentIndex: Int
    let progress: CGFloat
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Backdrop
            ZStack {
                if let backdropPath {
                    AsyncImage(url: MetadataClient().imageURL(path: backdropPath, width: 1920)) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .transition(.opacity.animation(.easeInOut(duration: 0.5)))
                        } else {
                            Color.black
                        }
                    }
                } else {
                    Color.black
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 520)
            .clipped()
            
            // Dark Gradient overlays
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .frame(height: 520)
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: 520)
            
            // Content
            HStack {
                VStack(alignment: .leading, spacing: 16) {
                    Spacer()
                    
                    // Logo or Title fallback
                    if let logoId {
                        AsyncLogoView(movieId: logoId, title: title ?? "", kind: .movie)
                    } else if let title {
                        Text(title)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 10, x: 0, y: 5)
                            .lineLimit(2)
                    }
                    
                    HStack {
                        ForEach(badges, id: \.self) { badge in
                            GlassBadge(badge)
                        }
                    }
                    
                    Text(overview)
                        .font(MovieBoxTypography.body)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(3)
                        .frame(maxWidth: 600, alignment: .leading)
                        .shadow(color: .black.opacity(0.8), radius: 4, x: 0, y: 2)
                    
                    HStack(spacing: 12) {
                        Button {
                            primaryAction()
                        } label: {
                            Label("Play Now", systemImage: "play.fill")
                                .font(.headline)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(.white, in: Capsule())
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                        
                        if secondaryAction != nil {
                            GlassButton(action: secondaryAction ?? {}) {
                                Label("Add To List", systemImage: "plus")
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                Spacer()
            }
            .padding(40)
            
            // Navigation Arrows (Top positioned, minimal)
            VStack {
                HStack {
                    Button {
                        navigationLeft()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .help("Previous")
                    
                    Spacer()
                    
                    Button {
                        navigationRight()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .help("Next")
                }
                .padding(.horizontal, 20)
                
                Spacer()
            }
            
            // Pagination Indicator
            HStack(spacing: 8) {
                ForEach(0..<movieCount, id: \.self) { index in
                    if index == currentIndex {
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.white.opacity(0.3))
                                .frame(width: 40, height: 4)
                            
                            Capsule()
                                .fill(.white)
                                .frame(width: max(0, 40 * progress), height: 4)
                        }
                    } else {
                        Circle()
                            .fill(.white.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .frame(height: 520)
        .ignoresSafeArea(edges: .horizontal)
    }
}

// MARK: - Rating Controls
struct RatingControls: View {
    let currentRating: Float?
    let onRate: (Float) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Your Rating:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    // Thumbs Down (-1)
                    Button {
                        onRate(-1)
                    } label: {
                        Image(systemName: (currentRating ?? 0) == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle((currentRating ?? 0) == -1 ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dislike (-1)")
                    
                    // Heart (+1)
                    Button {
                        onRate(1)
                    } label: {
                        Image(systemName: (currentRating ?? 0) == 1 ? "heart.fill" : "heart")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle((currentRating ?? 0) == 1 ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Like (+1)")
                    
                    // Fire (+2)
                    Button {
                        onRate(2)
                    } label: {
                        Image(systemName: (currentRating ?? 0) == 2 ? "flame.fill" : "flame")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle((currentRating ?? 0) == 2 ? .orange : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Love (+2)")
                    
                    if let currentRating, currentRating != 0 {
                        Button {
                            onRate(0)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear rating")
                    }
                }
                Spacer()
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 18)
        .background(Color.black.opacity(0.3))
    }
}


