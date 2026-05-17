import SwiftUI
import CoreMetadata
import DesignSystem
import Combine

struct HeroCarousel: View {
    @Environment(\.colorScheme) private var colorScheme

    let movies: [Movie]
    let action: (Movie) -> Void
    
    @State private var currentIndex: Int = 0
    @State private var progress: CGFloat = 0
    
    let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    /// Fade color follows the system appearance so the carousel dissolves
    /// into the surrounding chrome instead of always fading to black under
    /// a light-mode UI.
    private var fadeColor: Color {
        colorScheme == .dark ? .black : .white
    }

    /// Foreground color for hero text/arrows/dots — the opposite of
    /// `fadeColor` so it stays legible against the faded backdrop.
    private var contentColor: Color {
        colorScheme == .dark ? .white : .black
    }

    var body: some View {
        guard !movies.isEmpty else { return AnyView(EmptyView()) }
        let currentMovie = movies[currentIndex]
        
        return AnyView(
            ZStack(alignment: .bottom) {
                // Background Backdrop
                ZStack {
                    if let backdropPath = currentMovie.backdropPath {
                        AsyncImage(url: MetadataClient().imageURL(path: backdropPath, width: 1920)) { phase in
                            if let image = phase.image {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .transition(.opacity.animation(.easeInOut(duration: 0.5)))
                            } else {
                                fadeColor
                            }
                        }
                    } else {
                        fadeColor
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 620)
                .clipped()
                .id("hero-bg-\(currentIndex)")
                
                // Gradient overlays — tinted by `fadeColor` so the carousel
                // edges blend into the page background in both color schemes.
                LinearGradient(colors: [.clear, fadeColor.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 620)

                
                // Content
                HStack {
                    VStack(alignment: .leading, spacing: 20) {
                        Spacer()
                        
                        // Logo or Native Title fallback
                        AsyncLogoView(movieId: currentMovie.id, title: currentMovie.title, kind: .movie)
                        
                        HStack {
                            GlassBadge("Trending")
                            // TMDB community rating — the real IMDb score is only
                            // available after we hit /api/title bundle (detail screen).
                            GlassBadge(String(format: "%.1f TMDB", currentMovie.voteAverage), color: MovieBoxColors.accent)
                        }
                        
                        Text(currentMovie.overview)
                            .font(MovieBoxTypography.body)
                            .foregroundStyle(contentColor.opacity(0.9))
                            .lineLimit(3)
                            .frame(maxWidth: 600, alignment: .leading)
//                            .shadow(color: fadeColor.opacity(0.6), radius: 4, x: 0, y: 2)
                        
                        Button {
                            action(currentMovie)
                        } label: {
                            Label("Play Now", systemImage: "play.fill")
                                .font(.headline)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(.white, in: Capsule())
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 12)
                        .padding(.bottom, 60)
                    }
                    Spacer()
                }
                .padding(40)
                
                // Navigation Arrows (centered vertically)
                  VStack(spacing: 0) {
                       Spacer()
                           .padding(.top, 20)
                       
                       HStack {
                           Button {
                               withAnimation(.easeInOut) {
                                   currentIndex = (currentIndex - 1 + movies.count) % movies.count
                                   progress = 0
                               }
                           } label: {
                               Image(systemName: "chevron.left")
                                   .font(.system(size: 18, weight: .light))
                                   .foregroundStyle(contentColor)
                                   .padding(8)
                           }
                           .buttonStyle(.plain)
                           .help("Previous movie")
                           
                           Spacer()
                           
                           Button {
                               withAnimation(.easeInOut) {
                                   currentIndex = (currentIndex + 1) % movies.count
                                   progress = 0
                               }
                           } label: {
                               Image(systemName: "chevron.right")
                                   .font(.system(size: 18, weight: .light))
                                   .foregroundStyle(contentColor)
                                   .padding(8)
                           }
                           .buttonStyle(.plain)
                           .help("Next movie")
                       }
                       .padding(.horizontal, 20)
                       
                       Spacer()
                   }
                 
                 // Pagination Indicator
                 HStack(spacing: 8) {
                     ForEach(0..<movies.count, id: \.self) { index in
                         if index == currentIndex {
                             ZStack(alignment: .leading) {
                                 Capsule()
                                     .fill(contentColor.opacity(0.3))
                                     .frame(width: 40, height: 4)
                                 
                                 Capsule()
                                     .fill(contentColor)
                                     .frame(width: max(0, 40 * progress), height: 4)
                             }
                         } else {
                             Circle()
                                 .fill(contentColor.opacity(0.3))
                                 .frame(width: 6, height: 6)
                         }
                     }
                 }
                 .padding(.bottom, 24)
             }
             .frame(height: 620)
             .ignoresSafeArea(edges: .horizontal)
             .contentShape(Rectangle())
             .onTapGesture {
                 action(currentMovie)
             }
             .highPriorityGesture(
                 DragGesture(minimumDistance: 30)
                     .onEnded { value in
                         let translation = value.translation.width
                         
                         if translation < -50 {
                             // Swipe left -> next
                             withAnimation(.easeInOut) {
                                 currentIndex = (currentIndex + 1) % movies.count
                                 progress = 0
                             }
                         } else if translation > 50 {
                             // Swipe right -> previous
                             withAnimation(.easeInOut) {
                                 currentIndex = (currentIndex - 1 + movies.count) % movies.count
                                 progress = 0
                             }
                         }
                     }
             )
             .onReceive(timer) { _ in
                 if progress < 1.0 {
                     progress += 0.05 / 5.0 // 5 seconds per slide
                 } else {
                     withAnimation(.easeInOut(duration: 0.5)) {
                         currentIndex = (currentIndex + 1) % movies.count
                         progress = 0
                     }
                 }
             }
         )
     }
 }
