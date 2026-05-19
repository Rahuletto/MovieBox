import CoreMetadata
import CorePlayer
import CoreStorage
import DesignSystem
import SwiftData
import SwiftUI

struct DetailHeroHeader: View {
      @Environment(\.modelContext) private var modelContext
      @Query private var storedMovies: [MovieRecord]
      
      let detail: MovieDetail
      let kind: MediaKind
      let techKinds: [MediaTechKind]
      let accessibilityTags: [String]
      let addToMyList: () -> Void
      let onRate: (Float) -> Void
      let onPlayNow: () -> Void
      let onPlayTrailer: () -> Void
      let currentRating: Float?
      var playButtonTitle: String = "Play Now"
      
      private var isInList: Bool {
          storedMovies.contains { $0.tmdbId == detail.movie.id }
      }

      private var releaseYear: String? {
          let year = detail.movie.releaseDate.prefix(4)
          return year.count == 4 ? String(year) : nil
      }

      private var starringNames: [String] {
          if let actors = detail.enrichment?.actors, !actors.isEmpty {
              return actors
                  .split(separator: ",")
                  .map { $0.trimmingCharacters(in: .whitespaces) }
                  .filter { !$0.isEmpty }
          }
          return detail.cast.map(\.name)
      }
      
      var body: some View {
          HStack(alignment: .bottom, spacing: 24) {
              VStack(alignment: .leading, spacing: 14) {
                  Group {
                      AsyncLogoView(movieId: detail.movie.id, title: detail.movie.title, kind: kind)

                      if !detail.movie.overview.isEmpty {
                          Text(detail.movie.overview)
                              .font(.subheadline)
                              .foregroundStyle(.white.opacity(0.88))
                              .lineLimit(4)
                              .frame(maxWidth: 640, alignment: .leading)
                      }

                      HStack(spacing: 12) {
                          MediaMetadataRibbon(
                              year: releaseYear,
                              runtimeMinutes: detail.movie.runtime,
                              contentRating: detail.enrichment?.rated,
                              accessibilityTags: accessibilityTags,
                              labelColor: .white.opacity(0.82),
                              outlineForeground: .white,
                              outlineStroke: Color.white.opacity(0.45)
                          ) {
                              if let imdbRating = detail.enrichment?.imdbRating {
                                  IMDBBadge(rating: imdbRating)
                              }
                          }

                          if let rt = detail.enrichment?.rottenTomatoes {
                              RottenTomatoesBadge(score: rt)
                          }
                      }

                      if !techKinds.isEmpty {
                          MediaTechBadgeRow(kinds: techKinds)
                      }

                      if !detail.genres.isEmpty {
                          Text(detail.genres.prefix(4).map(\.name).joined(separator: " · "))
                              .font(.subheadline)
                              .foregroundStyle(.white.opacity(0.82))
                      }
                  }
                  .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 3)

                  HStack(spacing: 12) {
                      Button(action: onPlayNow) {
                          Label(playButtonTitle, systemImage: "play.fill")
                              .font(.headline)
                              .padding(.horizontal, 16)
                              .padding(.vertical, 8)
                              .background(.white, in: Capsule())
                              .foregroundStyle(.black)
                      }
                      .buttonStyle(.plain)
                      .disabled(kind == .tv && playButtonTitle == "Select Episode")

                      GlassButton(action: addToMyList, glassStrength: .ultraThin) {
                          Label(isInList ? "Added to List" : "Add To My List", systemImage: isInList ? "checkmark" : "plus")
                      }
                  }

                  if detail.trailerURL != nil {
                      Button(action: onPlayTrailer) {
                          Label("Watch Trailer", systemImage: "play.circle")
                              .font(.subheadline)
                              .foregroundStyle(.white.opacity(0.75))
                      }
                      .buttonStyle(.plain)
                  }
              }
              .frame(maxWidth: 720, alignment: .leading)

              Spacer(minLength: 0)

              MediaStarringLine(
                  names: starringNames,
                  labelColor: .white.opacity(0.72),
                  nameColor: .white
              )
              .frame(maxWidth: 380, alignment: .trailing)
              .padding(.bottom, 2)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
      }
  }

private struct DetailHeader: View {
     let detail: MovieDetail
     let addToMyList: () -> Void
     let onRate: (Float) -> Void
     let onPlayTrailer: () -> Void
     let currentRating: Float?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(detail.movie.title)
                        .font(.title)
                        .foregroundStyle(.primary)
                    Text(detail.movie.overview)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                    HStack {
                        GlassBadge(String(format: "%.1f IMDb", detail.movie.voteAverage), color: MovieBoxColors.accent)
                        if let runtime = detail.movie.runtime {
                            GlassBadge("\(runtime) min")
                        }
                        ForEach(detail.genres.prefix(3)) { genre in
                            GlassBadge(genre.name)
                        }
                    }
                }
                Spacer()
            }

            HStack(spacing: 12) {
                GlassButton(action: addToMyList) {
                    Label("Add To My List", systemImage: "plus")
                }

                if detail.trailerURL != nil {
                    GlassButton(action: onPlayTrailer) {
                        Label("Play Trailer", systemImage: "play.circle")
                    }
                }

                Divider().frame(height: 24)

                Text("Rate:")
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
            }
        }
        .padding(28)
         .adaptiveGlass(cornerRadius: 28)
        }
        }
