import SwiftUI

struct GenreCard: Identifiable, Hashable {
    let id: Int
    let name: String
    let symbol: String
    let colors: [Color]

    static let movieGenres: [GenreCard] = [
        .init(id: 28, name: "Action", symbol: "burst.fill",
              colors: [Color(red: 0.90, green: 0.31, blue: 0.18), Color(red: 0.95, green: 0.62, blue: 0.16)]),
        .init(id: 12, name: "Adventure", symbol: "map.fill",
              colors: [Color(red: 0.18, green: 0.55, blue: 0.32), Color(red: 0.82, green: 0.88, blue: 0.22)]),
        .init(id: 16, name: "Animation", symbol: "sparkles",
              colors: [Color(red: 0.40, green: 0.20, blue: 0.85), Color(red: 0.95, green: 0.36, blue: 0.74)]),
        .init(id: 35, name: "Comedy", symbol: "face.smiling.inverse",
              colors: [Color(red: 0.18, green: 0.78, blue: 0.84), Color(red: 0.62, green: 0.92, blue: 0.46)]),
        .init(id: 80, name: "Crime", symbol: "shield.lefthalf.filled",
              colors: [Color(red: 0.42, green: 0.08, blue: 0.12), Color(red: 0.78, green: 0.15, blue: 0.16)]),
        .init(id: 99, name: "Documentary", symbol: "doc.text.image",
              colors: [Color(red: 0.30, green: 0.30, blue: 0.35), Color(red: 0.55, green: 0.55, blue: 0.62)]),
        .init(id: 18, name: "Drama", symbol: "theatermasks.fill",
              colors: [Color(red: 0.14, green: 0.27, blue: 0.55), Color(red: 0.32, green: 0.66, blue: 0.86)]),
        .init(id: 10751, name: "Family", symbol: "person.3.fill",
              colors: [Color(red: 0.96, green: 0.55, blue: 0.32), Color(red: 0.99, green: 0.82, blue: 0.42)]),
        .init(id: 14, name: "Fantasy", symbol: "wand.and.stars",
              colors: [Color(red: 0.32, green: 0.18, blue: 0.62), Color(red: 0.18, green: 0.72, blue: 0.74)]),
        .init(id: 27, name: "Horror", symbol: "moon.stars.fill",
              colors: [Color(red: 0.18, green: 0.06, blue: 0.10), Color(red: 0.92, green: 0.38, blue: 0.12)]),
        .init(id: 10402, name: "Music", symbol: "music.note",
              colors: [Color(red: 0.86, green: 0.26, blue: 0.52), Color(red: 0.96, green: 0.70, blue: 0.28)]),
        .init(id: 9648, name: "Mystery", symbol: "magnifyingglass",
              colors: [Color(red: 0.13, green: 0.16, blue: 0.22), Color(red: 0.35, green: 0.40, blue: 0.52)]),
        .init(id: 10749, name: "Romance", symbol: "heart.fill",
              colors: [Color(red: 0.92, green: 0.38, blue: 0.62), Color(red: 0.96, green: 0.72, blue: 0.80)]),
        .init(id: 878, name: "Sci-Fi", symbol: "globe.americas.fill",
              colors: [Color(red: 0.10, green: 0.20, blue: 0.45), Color(red: 0.40, green: 0.86, blue: 0.95)]),
        .init(id: 53, name: "Thriller", symbol: "bolt.fill",
              colors: [Color(red: 0.20, green: 0.08, blue: 0.32), Color(red: 0.78, green: 0.16, blue: 0.55)]),
        .init(id: 10752, name: "War", symbol: "shield.fill",
              colors: [Color(red: 0.38, green: 0.38, blue: 0.38), Color(red: 0.18, green: 0.18, blue: 0.18)]),
        .init(id: 37, name: "Western", symbol: "app.dashed",
              colors: [Color(red: 0.84, green: 0.52, blue: 0.18), Color(red: 0.95, green: 0.74, blue: 0.36)])
    ]
}

struct GenreCardView: View {
    let genre: GenreCard
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: genre.colors, startPoint: .topLeading, endPoint: .bottomTrailing)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                Image(systemName: genre.symbol)
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.18))
                    .rotationEffect(.degrees(-8))
                    .offset(x: 22, y: -28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .clipped()

                Text(genre.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 1)
                    .padding(16)
            }
            .aspectRatio(3/4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(genre.name) category")
    }
}
