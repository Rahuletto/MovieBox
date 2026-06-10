import AppKit
import CoreMLEngine
import CoreMetadata
import CorePlayer
import CoreStorage
import CoreStreaming
import CoreTorrent
import MovieBoxCore
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var appServices
    @Query private var settingsRows: [AppSettings]
    @State private var draft = SettingsDraft()
    @State private var isHydratingDraft = false
    @State private var hasLoadedSettings = false
    @State private var selectedTab: SettingsTab = .general
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case metadata = "Metadata"
        case torrents = "Torrents"
        case downloads = "Downloads"
        case playback = "Playback"
        case recommendations = "Recommendations"
        case advanced = "Advanced"

        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .general: return "gear"
            case .metadata: return "key"
            case .torrents: return "point.3.connected.trianglepath.dotted"
            case .downloads: return "arrow.down.circle"
            case .playback: return "play.rectangle"
            case .recommendations: return "brain.head.profile"
            case .advanced: return "wrench.and.screwdriver"
            }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.vertical, 4)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 190, max: 190)
            .toolbar(removing: .sidebarToggle) // Apply to sidebar list to hide toggle button
        } detail: {
            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsSection(draft: $draft)
                case .metadata:
                    MetadataSettingsSection(draft: $draft)
                case .torrents:
                    TorrentSettingsSection(draft: $draft)
                case .downloads:
                    DownloadSettingsSection(draft: $draft)
                case .playback:
                    PlaybackSettingsSection(draft: $draft)
                case .recommendations:
                    RecommendationSettingsSection()
                case .advanced:
                    AdvancedSettingsSection(draft: $draft)
                }
            }
            // Removing .navigationTitle(selectedTab.rawValue) from detail column to eliminate the "huge forehead"
        }
        .frame(minWidth: 800, idealWidth: 840, maxWidth: .infinity, minHeight: 520, idealHeight: 580, maxHeight: .infinity)
        .onChange(of: columnVisibility) { _, newValue in
            // Lock sidebar visibility state
            if newValue != .all {
                columnVisibility = .all
            }
        }
        .onAppear { loadSettings() }
        .onChange(of: settingsRows) { _, _ in loadSettings() }
        .onChange(of: draft) { _, _ in
            guard !isHydratingDraft, hasLoadedSettings else { return }
            save()
        }
    }

    private func loadSettings() {
        if let settings = settingsRows.first {
            isHydratingDraft = true
            draft = SettingsDraft(settings: settings)
            hasLoadedSettings = true
            isHydratingDraft = false
            return
        }
        guard !hasLoadedSettings else { return }
        hasLoadedSettings = true
    }

    private func save() {
        if let existing = settingsRows.first {
            draft.apply(to: existing)
            appServices.syncPlaybackPolicy(from: existing)
            appServices.applyDownloadDirectory(from: existing)
        } else {
            let newSettings = AppSettings()
            draft.apply(to: newSettings)
            modelContext.insert(newSettings)
            appServices.syncPlaybackPolicy(from: newSettings)
            appServices.applyDownloadDirectory(from: newSettings)
        }
        if let first = settingsRows.first {
            MovieBoxFileLogger.isDebugLoggingEnabled = first.debugLogging
            PlaybackLog.isEnabled = first.debugLogging
        }
        do {
            try modelContext.save()
            if let settings = settingsRows.first {
                AppSettingsBackupStore.save(from: settings)
            }
        } catch {
            NSLog("MovieBox Settings: failed to save — \(error.localizedDescription)")
        }
    }
}

// MARK: - Onboarding Movie Model

private struct OnboardingMovie: Identifiable, Hashable {
    let id: Int
    let title: String
    let posterPath: String?
    let genreIds: [Int]
}

private let fallbackMovies: [OnboardingMovie] = [
    OnboardingMovie(id: 27205, title: "Inception", posterPath: "/o0O0oMKstj2iIjgUmsm456qj7ku.jpg", genreIds: [28, 878, 12]),
    OnboardingMovie(id: 157336, title: "Interstellar", posterPath: "/gEU2QniE6E77NIbK8nEZ2KyJOSr.jpg", genreIds: [12, 878, 18]),
    OnboardingMovie(id: 155, title: "The Dark Knight", posterPath: "/qJ2tWw2mIMG44n6RozzLBrK7V53.jpg", genreIds: [28, 80, 18, 53]),
    OnboardingMovie(id: 680, title: "Pulp Fiction", posterPath: "/d5iIlvFJ20jkgGcy6QQzSnw6q6n.jpg", genreIds: [53, 80]),
    OnboardingMovie(id: 19995, title: "Avatar", posterPath: "/kyeE2xt24u614jbgBNzw6tqu8Jq.jpg", genreIds: [28, 12, 878, 14]),
    OnboardingMovie(id: 11, title: "Star Wars", posterPath: "/6FfV5Y2UmdWDm25mUP26e1517su.jpg", genreIds: [12, 28, 878]),
    OnboardingMovie(id: 603, title: "The Matrix", posterPath: "/f89U3wzqrjysmqK02juTYv08nDc.jpg", genreIds: [28, 878]),
    OnboardingMovie(id: 98, title: "Gladiator", posterPath: "/ty87cx0tU1qZ25n2o7gkA275rR5.jpg", genreIds: [28, 18, 12]),
    OnboardingMovie(id: 120, title: "Fellowship of the Ring", posterPath: "/6oom5QDN2187QWZI7D2yJjZZBsG.jpg", genreIds: [12, 14, 28]),
    OnboardingMovie(id: 597, title: "Titanic", posterPath: "/9xjZS241Cgu20tQjRMwACw6e9u7.jpg", genreIds: [18, 10749]),
    OnboardingMovie(id: 129, title: "Spirited Away", posterPath: "/39wmItIWsg5J4Zwgfs25JgHjGZv.jpg", genreIds: [16, 14, 12]),
    OnboardingMovie(id: 329, title: "Jurassic Park", posterPath: "/oQC651pTCnhN0Wd9Jp251VnNu8C.jpg", genreIds: [12, 28, 878, 53]),
    OnboardingMovie(id: 299534, title: "Avengers: Endgame", posterPath: "/or06K3g86eIWzCL3R2GlC68vt76.jpg", genreIds: [12, 878, 28]),
    OnboardingMovie(id: 244786, title: "Whiplash", posterPath: "/7D1e09tZ5r4KWv597J56v6723t7.jpg", genreIds: [18, 10402]),
    OnboardingMovie(id: 496243, title: "Parasite", posterPath: "/7IiTT05EX2Arv6v6U6x6iZ5uViX.jpg", genreIds: [35, 53, 18])
]

// MARK: - Movie Rating Card

private struct MovieRatingCard: View {
    let movie: OnboardingMovie
    let currentRating: Float?
    let onRate: (Float) -> Void
    let metadataMode: MetadataEndpointMode?
    @State private var isHovered = false
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Poster image or fallback
                Group {
                    if let posterPath = movie.posterPath,
                       let mode = metadataMode,
                       let url = MetadataClient(mode: mode).posterDisplayURL(posterPath: posterPath, backdropPath: nil) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            case .failure(_), .empty:
                                fallbackPoster
                            @unknown default:
                                fallbackPoster
                            }
                        }
                    } else {
                        fallbackPoster
                    }
                }
                .frame(width: 100, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                
                // Active rating glow/indicator
                if let currentRating {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(ratingColor(currentRating), lineWidth: 3)
                        .shadow(color: ratingColor(currentRating).opacity(0.5), radius: 6)
                    
                    // Small floating badge showing the rating icon
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: ratingIcon(currentRating))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(ratingColor(currentRating), in: Circle())
                                .shadow(radius: 3)
                                .offset(x: 4, y: -4)
                        }
                        Spacer()
                    }
                }
                
                // Hover overlay with rating actions
                if isHovered {
                    Color.black.opacity(0.65)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    
                    VStack(spacing: 12) {
                        Spacer()
                        
                        // Love button
                        Button {
                            onRate(2.0)
                        } label: {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(currentRating == 2.0 ? .orange : .white)
                                .frame(width: 28, height: 28)
                                .background(currentRating == 2.0 ? Color.orange.opacity(0.3) : Color.white.opacity(0.15), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Love")
                        
                        // Like button
                        Button {
                            onRate(1.0)
                        } label: {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(currentRating == 1.0 ? .pink : .white)
                                .frame(width: 28, height: 28)
                                .background(currentRating == 1.0 ? Color.pink.opacity(0.3) : Color.white.opacity(0.15), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Like")
                        
                        // Hate button
                        Button {
                            onRate(-1.0)
                        } label: {
                            Image(systemName: "hand.thumbsdown.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(currentRating == -1.0 ? .blue : .white)
                                .frame(width: 28, height: 28)
                                .background(currentRating == -1.0 ? Color.blue.opacity(0.3) : Color.white.opacity(0.15), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Hate")
                        
                        Spacer()
                    }
                    .transition(.opacity)
                }
            }
            .onHover { h in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = h
                }
            }
            
            // Movie Title
            Text(movie.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 100, height: 28, alignment: .top)
        }
    }
    
    private var fallbackPoster: some View {
        ZStack {
            LinearGradient(
                colors: [Color.gray.opacity(0.2), Color.gray.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            Image(systemName: "film")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
        }
        .frame(width: 100, height: 150)
    }
    
    private func ratingColor(_ val: Float) -> Color {
        if val == 2.0 { return .orange }
        if val == 1.0 { return .pink }
        if val == -1.0 { return .blue }
        return .clear
    }
    
    private func ratingIcon(_ val: Float) -> String {
        if val == 2.0 { return "flame.fill" }
        if val == 1.0 { return "heart.fill" }
        if val == -1.0 { return "hand.thumbsdown.fill" }
        return ""
    }
}

// MARK: - Recommendations Section

private struct RecommendationSettingsSection: View {
    @Query private var ratings: [RatingRecord]
    @Query private var storedMovies: [MovieRecord]
    @Query private var appSettings: [AppSettings]
    @Environment(\.modelContext) private var modelContext
    @StateObject private var trainer = RecommendationTrainer()
    
    @State private var movies: [OnboardingMovie] = []
    @State private var isLoadingMovies = false
    @State private var fetchError: String? = nil
    @State private var showInsights = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header panel
            VStack(alignment: .leading, spacing: 8) {
                Text("Select Movies You Love or Hate")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                
                HStack(spacing: 16) {
                    // Rating count summary
                    let ratedCount = ratings.count
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(ratedCount >= 5 ? .green : .secondary)
                        Text("\(ratedCount) Rated")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    
                    Spacer()
                    
                    // Train button
                    Button {
                        Task {
                            let candidates = await MovieRegistry.shared.allMovies()
                            await trainer.train(
                                ratings: ratings,
                                storedMovies: storedMovies,
                                candidates: candidates
                            )
                        }
                    } label: {
                        if trainer.isTraining {
                            Label("Training…", systemImage: "hourglass")
                        } else {
                            Label("Train Recommendations", systemImage: "brain")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(trainer.isTraining || ratings.isEmpty)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // Movies Grid Scroll
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if isLoadingMovies && movies.isEmpty {
                        VStack {
                            Spacer()
                            ProgressView("Loading movie catalog…")
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 120), spacing: 16)], spacing: 20) {
                            ForEach(movies) { movie in
                                MovieRatingCard(
                                    movie: movie,
                                    currentRating: currentRating(for: movie.id),
                                    onRate: { rating in
                                        rateMovie(movie, rating: rating)
                                    },
                                    metadataMode: appSettings.first?.metadataMode
                                )
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    
                    Divider()
                    
                    // Model Insights Collapsible
                    DisclosureGroup(isExpanded: $showInsights) {
                        VStack(alignment: .leading, spacing: 14) {
                            if let metrics = trainer.metrics {
                                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                                    GridRow {
                                        Text("Total signals:")
                                            .foregroundStyle(.secondary)
                                        Text("\(metrics.totalRatings)")
                                            .font(.system(.body, design: .monospaced))
                                    }
                                    GridRow {
                                        Text("Average explicit rating:")
                                            .foregroundStyle(.secondary)
                                        Text(String(format: "%.2f", metrics.avgRating))
                                            .font(.system(.body, design: .monospaced))
                                    }
                                    GridRow {
                                        Text("Model version:")
                                            .foregroundStyle(.secondary)
                                        Text(metrics.modelVersion)
                                            .font(.system(.body, design: .monospaced))
                                    }
                                    GridRow {
                                        Text("Trained at:")
                                            .foregroundStyle(.secondary)
                                        Text(metrics.trainedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.system(.body, design: .monospaced))
                                    }
                                }
                                
                                Text("Top Genre Affinities")
                                    .font(.headline)
                                    .padding(.top, 8)
                                
                                let affinities = topAffinities(from: metrics.affinityVector)
                                if affinities.isEmpty {
                                    Text("No affinities calculated yet.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(affinities, id: \.genreID) { row in
                                            HStack {
                                                Text("Genre \(row.genreID)")
                                                    .font(.system(size: 12))
                                                Spacer()
                                                Text(String(format: "%.3f", row.score))
                                                    .foregroundStyle(.secondary)
                                                    .font(.system(size: 12, design: .monospaced))
                                            }
                                        }
                                    }
                                    .frame(maxWidth: 320)
                                }
                            } else {
                                Text("No training metrics available. Tap 'Train Recommendations' to generate model insights.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    } label: {
                        Text("Model Insights & Details")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
                .padding(24)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            trainer.loadCachedMetrics()
            Task {
                await loadInitialMovies()
            }
        }
    }
    
    private func currentRating(for movieId: Int) -> Float? {
        ratings.first(where: { $0.tmdbId == movieId })?.rating
    }
    
    private func rateMovie(_ movie: OnboardingMovie, rating: Float) {
        if let existing = ratings.first(where: { $0.tmdbId == movie.id }) {
            if existing.rating == rating {
                modelContext.delete(existing)
            } else {
                existing.rating = rating
                existing.ratedAt = Date()
            }
        } else {
            let record = RatingRecord(
                tmdbId: movie.id,
                rating: rating,
                genres: movie.genreIds
            )
            modelContext.insert(record)
        }
        try? modelContext.save()
        
        if rating > 0 {
            loadSimilarMovies(for: movie)
        }
    }
    
    private func loadInitialMovies() async {
        guard let mode = appSettings.first?.metadataMode else {
            movies = fallbackMovies
            return
        }
        
        isLoadingMovies = true
        fetchError = nil
        let client = MetadataClient(mode: mode)
        
        do {
            let trending = try await client.movies(for: .trending)
            let popular = try await client.movies(for: .popular)
            
            await MainActor.run {
                var uniqueMovies: [OnboardingMovie] = []
                let allFetched = (trending + popular).prefix(30)
                for m in allFetched {
                    if !uniqueMovies.contains(where: { $0.id == m.id }) {
                        uniqueMovies.append(OnboardingMovie(
                            id: m.id,
                            title: m.title,
                            posterPath: m.posterPath,
                            genreIds: m.genreIds
                        ))
                    }
                }
                
                for fallback in fallbackMovies {
                    if !uniqueMovies.contains(where: { $0.id == fallback.id }) {
                        uniqueMovies.append(fallback)
                    }
                }
                
                self.movies = uniqueMovies
                self.isLoadingMovies = false
            }
        } catch {
            await MainActor.run {
                self.movies = fallbackMovies
                self.isLoadingMovies = false
            }
        }
    }
    
    private func loadSimilarMovies(for movie: OnboardingMovie) {
        guard let mode = appSettings.first?.metadataMode else { return }
        let client = MetadataClient(mode: mode)
        
        Task {
            if let firstGenre = movie.genreIds.first {
                do {
                    let discovered = try await client.discoverMovies(genreId: firstGenre)
                    await MainActor.run {
                        for m in discovered {
                            if !movies.contains(where: { $0.id == m.id }) {
                                let onboardingMovie = OnboardingMovie(
                                    id: m.id,
                                    title: m.title,
                                    posterPath: m.posterPath,
                                    genreIds: m.genreIds
                                )
                                withAnimation(.spring()) {
                                    movies.insert(onboardingMovie, at: 0)
                                }
                            }
                        }
                    }
                } catch {
                    // Ignore errors
                }
            }
        }
    }
    
    private func topAffinities(from vector: [Int: Float]) -> [(genreID: Int, score: Float)] {
        vector
            .map { (genreID: $0.key, score: $0.value) }
            .sorted { $0.score > $1.score }
            .prefix(8)
            .map { $0 }
    }
}

// MARK: - General Section

private struct GeneralSettingsSection: View {
    @Binding var draft: SettingsDraft

    var body: some View {
        Form {
            Section("Language") {
                Picker("Interface Language", selection: $draft.interfaceLanguage) {
                    Text("System Default").tag("")
                    Text("English").tag("en")
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                    Text("Japanese").tag("ja")
                }
            }

            Section("Region") {
                Picker("Content Region", selection: $draft.contentRegion) {
                    Text("United States").tag("US")
                    Text("United Kingdom").tag("GB")
                    Text("Canada").tag("CA")
                    Text("Australia").tag("AU")
                    Text("India").tag("IN")
                    Text("Germany").tag("DE")
                    Text("France").tag("FR")
                    Text("Japan").tag("JP")
                }

            }

            UpdatesSettingsSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Updates Section

private struct UpdatesSettingsSection: View {
    @State private var automaticChecks = AppUpdater.shared.automaticallyChecksForUpdates

    var body: some View {
        Section("Updates") {
            LabeledContent("Version", value: AppVersion.display)

            Toggle("Check for updates automatically", isOn: $automaticChecks)
                .onChange(of: automaticChecks) { _, value in
                    AppUpdater.shared.automaticallyChecksForUpdates = value
                }

            Button("Check for Updates…") {
                AppUpdater.shared.checkForUpdates()
            }
            .disabled(!AppUpdater.shared.canCheckForUpdates)

            Link("View releases on GitHub", destination: AppUpdater.releasesPage)
        }
    }
}

// MARK: - Metadata Section

private struct MetadataSettingsSection: View {
    @Binding var draft: SettingsDraft

    var body: some View {
        Form {
            Section("Backend Proxy") {
                Toggle("Use local backend (wrangler dev)", isOn: $draft.useLocalBackend)
                if draft.useLocalBackend {
                    LabeledContent("Proxy URL", value: BackendProxyURL.local)

                } else {
                    TextField(
                        "Proxy Base URL",
                        text: $draft.proxyBaseURL,
                        prompt: Text(BackendProxyURL.production)
                    )
                }
                SecureField("App Token", text: $draft.appToken, prompt: Text("Enter token"))

            }

            Section("Direct API Keys") {
                SecureField("TMDB Bearer Token", text: $draft.tmdbBearerToken, prompt: Text("Enter token"))
                SecureField("OMDb API Key", text: $draft.omdbAPIKey, prompt: Text("Enter key"))

            }

            Section("Image Quality") {
                Picker("Poster Size", selection: $draft.posterSize) {
                    Text("Small (185px)").tag("w185")
                    Text("Medium (342px)").tag("w342")
                    Text("Large (500px)").tag("w500")
                    Text("Original").tag("original")
                }
                Picker("Backdrop Size", selection: $draft.backdropSize) {
                    Text("Medium (780px)").tag("w780")
                    Text("Large (1280px)").tag("w1280")
                    Text("Original").tag("original")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Torrent Section

private struct TorrentSettingsSection: View {
    @Binding var draft: SettingsDraft
    @State private var catalog: [TorrentIndexerCatalogEntry] = []
    @State private var defaultEnabledIndexerIDs: [String] = Array(TorrentIndexerPreferences.defaultIDs)
    @State private var catalogError: String?
    @State private var isLoadingCatalog = false

    private var catalogIDs: Set<String> { Set(catalog.map(\.id)) }

    var body: some View {
        Form {
            Section {
                if isLoadingCatalog {
                    ProgressView("Loading indexers from backend…")
                } else if let catalogError {
                    Text(catalogError)
                        .foregroundStyle(.secondary)
                    Text("Configure Metadata → Backend Proxy, then reopen Settings.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if catalog.isEmpty {
                    Text("No indexers returned. Deploy the latest backend Worker.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("Enable all") {
                            draft.enabledTorrentIndexers = TorrentIndexerPreferences.serialize(
                                Set(defaultEnabledIndexerIDs),
                                order: catalog.map(\.id)
                            )
                        }
                        Button("Disable all") { draft.enabledTorrentIndexers = "" }
                    }
                    ForEach(catalog) { entry in
                        Toggle(entry.name, isOn: indexerBinding(entry.id))
                    }
                }
            } header: {
                Text("Search Providers")
            }

            Section("Torrent Behavior") {
                Toggle("Seed after download completes", isOn: $draft.enableSeeding)
                Stepper("Max Active Downloads: \(draft.maxActiveDownloads)", value: $draft.maxActiveDownloads, in: 1...5)
                Stepper("Max Active Uploads: \(draft.maxActiveUploads)", value: $draft.maxActiveUploads, in: 1...10)
            }
        }
        .formStyle(.grouped)
        .task { await loadCatalog() }
        .onChange(of: draft.proxyBaseURL) { _, _ in Task { await loadCatalog() } }
        .onChange(of: draft.useLocalBackend) { _, _ in Task { await loadCatalog() } }
        .onChange(of: draft.appToken) { _, _ in Task { await loadCatalog() } }
    }

    private func indexerBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: {
                TorrentIndexerPreferences
                    .parseCSV(draft.enabledTorrentIndexers, knownIDs: catalogIDs)
                    .contains(id)
            },
            set: { enabled in
                var set = TorrentIndexerPreferences.parseCSV(draft.enabledTorrentIndexers, knownIDs: catalogIDs)
                if enabled { set.insert(id) } else { set.remove(id) }
                draft.enabledTorrentIndexers = TorrentIndexerPreferences.serialize(set, order: catalog.map(\.id))
                draft.enableYTS = set.contains("yts")
            }
        )
    }

    private func loadCatalog() async {
        let base = BackendProxyURL.resolved(proxyBaseURL: draft.proxyBaseURL, useLocalBackend: draft.useLocalBackend)
        guard let url = URL(string: base), !base.isEmpty, !draft.appToken.isEmpty else {
            catalog = fallbackCatalog
            catalogError = nil
            return
        }
        isLoadingCatalog = true
        catalogError = nil
        defer { isLoadingCatalog = false }
        do {
            let client = BackendTorrentConfigClient(baseURL: url, appToken: draft.appToken)
            let config = try await client.fetchCatalog()
            catalog = config.indexers
            defaultEnabledIndexerIDs = config.defaultEnabledIndexerIDs
        } catch {
            catalog = fallbackCatalog
            catalogError = error.localizedDescription
        }
    }

    private var fallbackCatalog: [TorrentIndexerCatalogEntry] {
        TorrentIndexerPreferences.defaultIDs.map { id in
            TorrentIndexerCatalogEntry(
                id: id,
                name: id.capitalized,
                description: "Enable backend proxy to load live catalog.",
                kinds: ["movie", "tv"]
            )
        }
    }
}

// MARK: - Downloads Section

private struct DownloadSettingsSection: View {
    @Binding var draft: SettingsDraft
    @State private var cacheSizeString = "Calculating…"

    var body: some View {
        Form {
            Section("Location") {
                LabeledContent("Download Folder") {
                    HStack {
                        TextField(
                            "",
                            text: $draft.defaultDownloadPath,
                            prompt: Text(DownloadStorage.defaultRootDirectory().path)
                        )
                        .frame(maxWidth: 240)
                        Button("Choose…", action: chooseFolder)
                    }
                }

                if DownloadFolderAccess.hasStoredBookmark {
                    Label("Custom folder access granted", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Section("Cleanup") {
                Toggle("Delete torrent file after download", isOn: $draft.deleteTorrentAfterDownload)
                Toggle("Remove completed downloads after 7 days", isOn: $draft.autoRemoveCompleted)
                
                LabeledContent("Active Cache Size") {
                    HStack(spacing: 8) {
                        Text(cacheSizeString)
                            .foregroundStyle(.secondary)
                        
                        Button("Clear Cache") {
                            clearCache()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

            }
        }
        .formStyle(.grouped)
        .onAppear {
            updateCacheSize()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the folder where MovieBox should save downloads (e.g. Movies or MovieBox)."
        panel.prompt = "Grant Access"
        let movies = DownloadStorage.realUserHomeDirectory().appendingPathComponent("Movies", isDirectory: true)
        if FileManager.default.fileExists(atPath: movies.path) {
            panel.directoryURL = movies
        }
        if panel.runModal() == .OK, let url = panel.url {
            DownloadFolderAccess.storeUserSelectedFolder(url)
            let movieBox = url.lastPathComponent == "MovieBox"
                ? url
                : url.appendingPathComponent("MovieBox", isDirectory: true)
            draft.defaultDownloadPath = movieBox.path
            _ = DownloadFolderAccess.beginAccess(to: movieBox)
            try? DownloadStorage.prepareDirectory(at: movieBox)
        }
    }
    
    private func updateCacheSize() {
        Task {
            let size = await calculateCacheSizeAsync()
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            cacheSizeString = formatter.string(fromByteCount: size)
        }
    }

    private func calculateCacheSizeAsync() async -> Int64 {
        return await Task.detached(priority: .background) {
            return Self.getCacheDirSize()
        }.value
    }

    private static func getCacheDirSize() -> Int64 {
        guard let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.marban.MovieBox", isDirectory: true) else { return 0 }
        
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cacheURL.path) else { return 0 }
        
        var size: Int64 = 0
        if let enumerator = fileManager.enumerator(at: cacheURL, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            while let url = enumerator.nextObject() as? URL {
                if let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
                   let fileSize = resourceValues.fileSize {
                    size += Int64(fileSize)
                }
            }
        }
        return size
    }

    private func clearCache() {
        guard let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.marban.MovieBox", isDirectory: true) else { return }
        
        Task {
            await Task.detached(priority: .userInitiated) {
                let fileManager = FileManager.default
                if let contents = try? fileManager.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: nil) {
                    for item in contents {
                        try? fileManager.removeItem(at: item)
                    }
                }
            }.value
            updateCacheSize()
        }
    }
}

// MARK: - Subtitle Preview Card

private struct SubtitlePreviewCard: View {
    let style: String
    let fontSize: CGFloat
    
    var body: some View {
        VStack {
            Spacer()
            
            let appearance = SubtitleAppearance.from(settingsValue: style)
            switch appearance {
            case .modern:
                Text("I must not fear. Fear is the mind-killer.")
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
                
            case .largeWhite:
                Text("I must not fear. Fear is the mind-killer.")
                    .font(.system(size: fontSize * 1.25, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 6, y: 2)
                
            case .yellowBlack:
                Text("I must not fear. Fear is the mind-killer.")
                    .font(.system(size: fontSize * 1.05, weight: .bold))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                
            case .system:
                Text("I must not fear. Fear is the mind-killer.")
                    .font(.system(size: fontSize * 1.05, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 4, y: 2)
            }
            
            Spacer()
        }
        .frame(height: 120)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                Image("subtitle-preview-bg")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 120)
                    .clipped()
                
                LinearGradient(
                    colors: [.clear, .black.opacity(0.45)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Playback Section

private struct PlaybackSettingsSection: View {
    @Binding var draft: SettingsDraft

    var body: some View {
        Form {
            Section("Quality") {
                Picker("Preferred Quality", selection: $draft.preferredQuality) {
                    Text("Best Available").tag("best")
                    Text("4K (2160p)").tag("4k")
                    Text("1080p").tag("1080p")
                    Text("720p").tag("720p")
                }
                Toggle("Prefer HDR when available", isOn: $draft.preferHDR)
                Toggle("Strict HDR metadata validation", isOn: $draft.strictHDRValidation)

            }

            Section("Audio") {
                TextField("Preferred Language", text: $draft.preferredAudioLang, prompt: Text("en"))

                Picker("Audio Format Priority", selection: $draft.audioFormatPriority) {
                    Text("Best Available").tag("best")
                    Text("Dolby Atmos").tag("atmos")
                    Text("DTS-HD").tag("dtshd")
                    Text("TrueHD").tag("truehd")
                    Text("EAC3").tag("eac3")
                    Text("AAC").tag("aac")
                }
            }

            Section("Subtitles") {
                SubtitlePreviewCard(style: draft.subtitleStyle, fontSize: draft.subtitleFontSize)
                
                TextField("Preferred Language", text: $draft.preferredSubtitleLang, prompt: Text("en"))
                Toggle("Enable subtitles by default", isOn: $draft.subtitlesEnabled)
                Picker("Subtitle Style", selection: $draft.subtitleStyle) {
                    ForEach(SubtitleAppearance.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                HStack {
                    Text("Subtitle size")
                    Slider(value: $draft.subtitleFontSize, in: 14...36, step: 1)
                    Text("\(Int(draft.subtitleFontSize)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Section("Player Behavior") {
                Toggle("Resume playback from last position", isOn: $draft.resumePlayback)
                Toggle("Enter full screen on playback", isOn: $draft.fullScreenOnPlayback)
                Stepper("Skip intro duration: \(draft.skipIntroDuration)s", value: $draft.skipIntroDuration, in: 0...30)
            }

            Section("Developer") {
                Toggle("Show streaming samples on Downloads", isOn: $draft.showStreamingSamples)

            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced Section

private struct AdvancedSettingsSection: View {
    @Binding var draft: SettingsDraft

    var body: some View {
        Form {
            Section("Network") {
                TextField("HTTP Proxy URL", text: $draft.httpProxyURL, prompt: Text("http://proxy:port"))
                Toggle("Use HTTP proxy for all requests", isOn: $draft.useHTTPProxy)
                    .disabled(draft.httpProxyURL.isEmpty)
                Stepper("Request Timeout: \(draft.requestTimeout)s", value: $draft.requestTimeout, in: 5...60)
            }

            Section("Cache") {
                Stepper("Image Cache Size: \(draft.imageCacheSize) MB", value: $draft.imageCacheSize, in: 50...500, step: 50)
                Stepper("Metadata Cache TTL: \(draft.metadataCacheTTL) min", value: $draft.metadataCacheTTL, in: 5...1440, step: 5)
            }

            Section("Logging") {
                Toggle("Enable debug logging", isOn: $draft.debugLogging)
                Toggle("Log torrent activity", isOn: $draft.logTorrentActivity)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Draft Structure

private struct SettingsDraft: Equatable {
    var proxyBaseURL = ""
    var useLocalBackend = false
    var appToken = ""
    var tmdbBearerToken = ""
    var omdbAPIKey = ""
    var defaultDownloadPath = ""
    var preferredQuality = "best"
    var preferredAudioLang = "en"
    var preferredSubtitleLang = "en"
    var enableYTS = true
    var enabledTorrentIndexers = "torrentio,yts,eztv,piratebay,1337x,bitsearch,torrentdownload"
    var enableSeeding = true
    var maxActiveDownloads = 2
    var maxActiveUploads = 5
    var downloadSpeedLimit = "0"
    var uploadSpeedLimit = "0"
    var deleteTorrentAfterDownload = false
    var autoRemoveCompleted = false
    var preferHDR = true
    var strictHDRValidation = false
    var allowTranscodeFallback = true
    var subtitlesEnabled = true
    var subtitleStyle = "modern"
    var subtitleFontSize = 20.0
    var audioFormatPriority = "best"
    var resumePlayback = true
    var fullScreenOnPlayback = false
    var skipIntroDuration = 0
    var onLaunchAction = "home"
    var interfaceLanguage = ""
    var contentRegion = "US"
    var posterSize = "w342"
    var backdropSize = "w1280"
    var httpProxyURL = ""
    var useHTTPProxy = false
    var requestTimeout = 20
    var imageCacheSize = 250
    var metadataCacheTTL = 60
    var debugLogging = false
    var logTorrentActivity = false
    var showStreamingSamples = false

    init(settings: AppSettings? = nil) {
        guard let settings else { return }
        proxyBaseURL = settings.proxyBaseURL
        useLocalBackend = settings.useLocalBackend
        appToken = settings.appToken
        tmdbBearerToken = settings.tmdbBearerToken
        omdbAPIKey = settings.omdbAPIKey
        defaultDownloadPath = settings.defaultDownloadPath
        preferredQuality = settings.preferredQuality
        preferredAudioLang = settings.preferredAudioLang
        preferredSubtitleLang = settings.preferredSubtitleLang
        enableYTS = settings.enableYTS
        enabledTorrentIndexers = settings.enabledTorrentIndexers
        enableSeeding = settings.enableSeeding
        maxActiveDownloads = settings.maxActiveDownloads
        maxActiveUploads = settings.maxActiveUploads
        downloadSpeedLimit = String(settings.maxDownloadSpeedKBps)
        uploadSpeedLimit = String(settings.maxUploadSpeedKBps)
        deleteTorrentAfterDownload = settings.deleteTorrentAfterDownload
        autoRemoveCompleted = settings.autoRemoveCompleted
        preferHDR = settings.preferHDR
        strictHDRValidation = settings.strictHDRValidation
        allowTranscodeFallback = settings.allowTranscodeFallback
        subtitlesEnabled = settings.subtitlesEnabled
        subtitleStyle = settings.subtitleStyle
        subtitleFontSize = settings.subtitleFontSize
        audioFormatPriority = settings.audioFormatPriority
        resumePlayback = settings.resumePlayback
        fullScreenOnPlayback = settings.fullScreenOnPlayback
        skipIntroDuration = settings.skipIntroDuration
        onLaunchAction = settings.onLaunchAction
        interfaceLanguage = settings.interfaceLanguage
        contentRegion = settings.contentRegion
        posterSize = settings.posterSize
        backdropSize = settings.backdropSize
        httpProxyURL = settings.httpProxyURL
        useHTTPProxy = settings.useHTTPProxy
        requestTimeout = settings.requestTimeout
        imageCacheSize = settings.imageCacheSize
        metadataCacheTTL = settings.metadataCacheTTL
        debugLogging = settings.debugLogging
        logTorrentActivity = settings.logTorrentActivity
        showStreamingSamples = settings.showStreamingSamples
    }

    func apply(to settings: AppSettings) {
        settings.proxyBaseURL = proxyBaseURL
        settings.useLocalBackend = useLocalBackend
        settings.appToken = appToken
        settings.tmdbBearerToken = tmdbBearerToken
        settings.omdbAPIKey = omdbAPIKey
        settings.defaultDownloadPath = defaultDownloadPath
        settings.preferredQuality = preferredQuality
        settings.preferredAudioLang = preferredAudioLang
        settings.preferredSubtitleLang = preferredSubtitleLang
        settings.enableYTS = TorrentIndexerPreferences.parseCSV(enabledTorrentIndexers).contains("yts")
        settings.enabledTorrentIndexers = enabledTorrentIndexers
        settings.enableSeeding = enableSeeding
        settings.maxActiveDownloads = maxActiveDownloads
        settings.maxActiveUploads = maxActiveUploads
        settings.maxDownloadSpeedKBps = Int(downloadSpeedLimit) ?? 0
        settings.maxUploadSpeedKBps = Int(uploadSpeedLimit) ?? 0
        settings.deleteTorrentAfterDownload = deleteTorrentAfterDownload
        settings.autoRemoveCompleted = autoRemoveCompleted
        settings.preferHDR = preferHDR
        settings.strictHDRValidation = strictHDRValidation
        settings.allowTranscodeFallback = allowTranscodeFallback
        settings.subtitlesEnabled = subtitlesEnabled
        settings.subtitleStyle = subtitleStyle
        settings.subtitleFontSize = subtitleFontSize
        settings.audioFormatPriority = audioFormatPriority
        settings.resumePlayback = resumePlayback
        settings.fullScreenOnPlayback = fullScreenOnPlayback
        settings.skipIntroDuration = skipIntroDuration
        settings.onLaunchAction = onLaunchAction
        settings.interfaceLanguage = interfaceLanguage
        settings.contentRegion = contentRegion
        settings.posterSize = posterSize
        settings.backdropSize = backdropSize
        settings.httpProxyURL = httpProxyURL
        settings.useHTTPProxy = useHTTPProxy
        settings.requestTimeout = requestTimeout
        settings.imageCacheSize = imageCacheSize
        settings.metadataCacheTTL = metadataCacheTTL
        settings.debugLogging = debugLogging
        settings.logTorrentActivity = logTorrentActivity
        settings.showStreamingSamples = showStreamingSamples
    }
}
