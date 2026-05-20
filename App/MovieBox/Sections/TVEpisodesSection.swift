import SwiftUI
import CoreMetadata
import DesignSystem

private enum TVEpisodeCardMetrics {
    static let width: CGFloat = 300
    static let height: CGFloat = 168
}

struct TVEpisodesSection: View {
    let showId: Int
    let seasons: [TVSeasonSummary]
    let episodes: [TVEpisode]
    let selectedSeason: Int
    var selectedEpisodeID: Int? = nil
    var isLoadingSeasons: Bool = false
    var seasonsLoadFailed: Bool = false
    let isLoadingEpisodes: Bool
    let onSeasonChange: (Int) -> Void
    let onEpisodeSelect: (TVEpisode) -> Void
    var onRetrySeasons: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        // Loading seasons
        if isLoadingSeasons && seasons.isEmpty {
            CenteredEmptyState(
                icon: "tv",
                title: "Loading Seasons",
                description: "Finding available seasons...",
                isLoading: true
            )
        }
        // Failed to load seasons
        else if seasonsLoadFailed && seasons.isEmpty {
            VStack(spacing: 20) {
                Spacer()
                
                VStack(spacing: 16) {
                    Image(systemName: "tv")
                        .font(.system(size: 48, weight: .light))
                        .opacity(0.7)
                    
                    VStack(spacing: 8) {
                        Text("Couldn't load seasons")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.primary)
                        
                        Text("Check your connection and try again.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
            }
            .frame(height: TVEpisodeCardMetrics.height)
        }
        // No seasons available
        else if seasons.isEmpty {
            CenteredEmptyState(
                icon: "film.stack",
                title: "No Seasons Available",
                description: "This show doesn't have any seasons available.",
                isLoading: false
            )
        }
        // Seasons loaded - show picker + episodes
        else {
            VStack(alignment: .leading, spacing: 16) {
                // Season picker
                if seasons.count > 1 {
                    Menu {
                        ForEach(seasons) { season in
                            Button(season.name) {
                                onSeasonChange(season.seasonNumber)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "tv.inset.filled")
                                .foregroundStyle(.secondary)
                            Text(selectedSeasonLabel)
                                .font(.title3.weight(.semibold))
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(white: 0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, DetailLayoutMetrics.shelfSideInset)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "tv.inset.filled")
                            .foregroundStyle(.secondary)
                        Text(selectedSeasonLabel)
                            .font(.title3.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .padding(.horizontal, DetailLayoutMetrics.shelfSideInset)
                }

                // Episodes
                episodesContent
            }
        }
    }

    @ViewBuilder
    private var episodesContent: some View {
        if isLoadingEpisodes {
            CenteredEmptyState(
                icon: "tv",
                title: "Loading Episodes",
                description: "Finding available episodes...",
                isLoading: true
            )
        } else if episodes.isEmpty {
            CenteredEmptyState(
                icon: "rectangle.dashed",
                title: "No Episodes Found",
                description: "This season doesn't have any episodes available.",
                isLoading: false
            )
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(episodes) { episode in
                        TVEpisodeCard(
                            episode: episode,
                            isSelected: episode.id == selectedEpisodeID
                        ) {
                            onEpisodeSelect(episode)
                        }
                    }
                }
                .padding(.horizontal, DetailLayoutMetrics.shelfSideInset)
            }
            .scrollIndicators(.hidden)
            .frame(height: TVEpisodeCardMetrics.height)
        }
    }

    private var selectedSeasonLabel: String {
        seasons.first(where: { $0.seasonNumber == selectedSeason })?.name ?? "Season \(selectedSeason)"
    }
}

private struct TVEpisodeCard: View {
    let episode: TVEpisode
    var isSelected: Bool = false
    let onSelect: () -> Void
    private var isUpcoming: Bool { episode.isUpcoming }

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .bottomLeading) {
                episodeStill
                    .frame(width: TVEpisodeCardMetrics.width, height: TVEpisodeCardMetrics.height)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.35), .black.opacity(0.88)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("EPISODE \(episode.episodeNumber)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(episode.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if isUpcoming {
                        upcomingPill
                    }

                    if !episode.overview.isEmpty {
                        Text(episode.overview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }

                    HStack {
                        if let runtime = episode.runtime, runtime > 0 {
                            Image(systemName: "clock.fill")
                                .font(.caption)
                            Text("\(runtime)m")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if isUpcoming, let label = episode.formattedAirDate {
                            Image(systemName: "calendar")
                                .font(.caption)
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else if isUpcoming {
                            Image(systemName: "clock.badge")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "play.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
            }
            .frame(width: TVEpisodeCardMetrics.width, height: TVEpisodeCardMetrics.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
            }
        }
        .buttonStyle(.plain)
        .disabled(isUpcoming)
        .opacity(isUpcoming ? 0.88 : 1)
    }

    @ViewBuilder
    private var episodeStill: some View {
        if let path = episode.stillPath,
           let url = MetadataClient().imageURL(path: path, width: 500) {
            CachedImageView(url: url) {
                stillPlaceholder
            } content: { image in
                image.resizable().scaledToFill()
            }
        } else {
            stillPlaceholder
        }
    }

    private var stillPlaceholder: some View {
        Rectangle()
            .fill(Color(white: 0.12))
            .overlay {
                Image(systemName: "tv")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }

    private var upcomingPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock.badge")
                .font(.caption2)
            Text("Upcoming")
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.14), in: Capsule(style: .continuous))
    }
}

private extension TVEpisode {
    var isUpcoming: Bool {
        guard let airDate else { return false }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: airDate) else { return false }
        return date > Calendar.current.startOfDay(for: Date())
    }

    var formattedAirDate: String? {
        guard let airDate else { return nil }
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: airDate) else { return airDate }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .none
        return display.string(from: date)
    }
}

