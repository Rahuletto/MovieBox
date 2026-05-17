import SwiftUI
import CoreMetadata
import DesignSystem
import Combine

struct HeroCarousel: View {
    let movies: [Movie]
    let action: (Movie) -> Void
    
    @State private var currentIndex: Int = 0
    @State private var progress: CGFloat = 0
    
    let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    
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
                .id("hero-bg-\(currentIndex)")
                
                // Dark Gradient overlays
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 520)
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 520)
                
                // Content
                HStack {
                    VStack(alignment: .leading, spacing: 16) {
                        Spacer()
                        
                        // Logo or Native Title fallback
                        AsyncLogoView(movieId: currentMovie.id, title: currentMovie.title)
                        
                        HStack {
                            GlassBadge("Trending", color: .red)
                            GlassBadge(String(format: "%.1f IMDb", currentMovie.voteAverage), color: MovieBoxColors.accent)
                        }
                        
                        Text(currentMovie.overview)
                            .font(MovieBoxTypography.body)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(3)
                            .frame(maxWidth: 600, alignment: .leading)
                            .shadow(color: .black.opacity(0.8), radius: 4, x: 0, y: 2)
                        
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
                        .padding(.top, 8)
                    }
                    Spacer()
                }
                .padding(40)
                
                // Navigation Arrows (Top positioned, minimal)
                 VStack {
                      HStack {
                          Button {
                              withAnimation(.easeInOut) {
                                  currentIndex = (currentIndex - 1 + movies.count) % movies.count
                                  progress = 0
                              }
                          } label: {
                              Image(systemName: "chevron.left")
                                  .font(.system(size: 18, weight: .light))
                                  .foregroundStyle(.white)
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
                                  .foregroundStyle(.white)
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
             .contentShape(Rectangle())
             .onTapGesture {
                 action(currentMovie)
             }
             .gesture(
                 MagnificationGesture()
                     .onChanged { _ in }
                     .onEnded { _ in }
             )
             .gesture(
                 DragGesture(minimumDistance: 100)
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
