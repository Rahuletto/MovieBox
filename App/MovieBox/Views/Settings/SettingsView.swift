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

    var body: some View {
        TabView {
            Tab("General", systemImage: "gear") {
                GeneralSettingsSection(draft: $draft)
            }
            Tab("Metadata", systemImage: "key") {
                MetadataSettingsSection(draft: $draft)
            }
            Tab("Torrents", systemImage: "point.3.connected.trianglepath.dotted") {
                TorrentSettingsSection(draft: $draft)
            }
            Tab("Downloads", systemImage: "arrow.down.circle") {
                DownloadSettingsSection(draft: $draft)
            }
            Tab("Playback", systemImage: "play.rectangle") {
                PlaybackSettingsSection(draft: $draft)
            }
            Tab("Recommendations", systemImage: "brain.head.profile") {
                RecommendationSettingsSection()
            }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") {
                AdvancedSettingsSection(draft: $draft)
            }
        }
        .scenePadding()
        .frame(width: 550)
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
        } catch {
            NSLog("MovieBox Settings: failed to save — \(error.localizedDescription)")
        }
    }
}

// MARK: - Recommendations

private struct RecommendationSettingsSection: View {
    @Query private var ratings: [RatingRecord]
    @Query private var storedMovies: [MovieRecord]
    @StateObject private var trainer = RecommendationTrainer()

    var body: some View {
        Form {
            Section("Model State") {
                LabeledContent("Explicit ratings", value: "\(ratings.count)")
                LabeledContent("Watch history items", value: "\(storedMovies.filter { $0.lastWatchedAt != nil }.count)")
                LabeledContent("Watchlist items", value: "\(storedMovies.filter { $0.watchlistAddedAt != nil }.count)")
            }

            Section("Training") {
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
                .disabled(trainer.isTraining)

                if let error = trainer.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if let metrics = trainer.metrics {
                Section("Latest Metrics") {
                    LabeledContent("Total signals", value: "\(metrics.totalRatings)")
                    LabeledContent("Average explicit rating", value: String(format: "%.2f", metrics.avgRating))
                    LabeledContent("Model version", value: metrics.modelVersion)
                    LabeledContent("Trained at", value: metrics.trainedAt.formatted(date: .abbreviated, time: .shortened))
                }

                Section("Top Genre Affinities") {
                    ForEach(topAffinities(from: metrics.affinityVector), id: \.genreID) { row in
                        HStack {
                            Text("Genre \(row.genreID)")
                            Spacer()
                            Text(String(format: "%.3f", row.score))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            trainer.loadCachedMetrics()
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

// MARK: - General

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
                Text("Affects trending and popular content rankings.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Metadata

private struct MetadataSettingsSection: View {
    @Binding var draft: SettingsDraft

    var body: some View {
        Form {
            Section("Backend Proxy") {
                Toggle("Use local backend (wrangler dev)", isOn: $draft.useLocalBackend)
                if draft.useLocalBackend {
                    LabeledContent("Proxy URL", value: BackendProxyURL.local)
                    Text("Start the worker: `cd Backend && bun run dev`")
                        .foregroundStyle(.secondary)
                } else {
                    TextField(
                        "Proxy Base URL",
                        text: $draft.proxyBaseURL,
                        prompt: Text(BackendProxyURL.production)
                    )
                }
                SecureField("App Token", text: $draft.appToken, prompt: Text("Enter token"))
                Text("When configured, metadata and torrent search route through your Hono backend.")
                    .foregroundStyle(.secondary)
            }

            Section("Direct API Keys") {
                SecureField("TMDB Bearer Token", text: $draft.tmdbBearerToken, prompt: Text("Enter token"))
                SecureField("OMDb API Key", text: $draft.omdbAPIKey, prompt: Text("Enter key"))
                Text("Used when no backend proxy is configured. TMDB is required for core functionality.\n\nNote: You can request a free API key from OMDb (free tier allows 1,000 daily requests) and paste it here.")
                    .foregroundStyle(.secondary)
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

// MARK: - Torrent

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
                        Toggle(isOn: indexerBinding(entry.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                Text(entry.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Search Providers")
            } footer: {
                Text("Providers are defined on your backend. Toggling here controls which indexers run for each search.")
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

// MARK: - Downloads

private struct DownloadSettingsSection: View {
    @Binding var draft: SettingsDraft

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
                Text(
                    """
                    Default: ~/Movies/MovieBox (App Sandbox → Movies Folder read/write). \
                    Choose… is only needed for a custom folder outside Movies.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if DownloadFolderAccess.hasStoredBookmark {
                    Label("Custom folder access granted", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Section("Speed Limits") {
                Picker("Download Speed", selection: $draft.downloadSpeedLimit) {
                    Text("Unlimited").tag("0")
                    Text("1 MB/s").tag("1024")
                    Text("5 MB/s").tag("5120")
                    Text("10 MB/s").tag("10240")
                    Text("25 MB/s").tag("25600")
                }
                Picker("Upload Speed", selection: $draft.uploadSpeedLimit) {
                    Text("Unlimited").tag("0")
                    Text("128 KB/s").tag("128")
                    Text("256 KB/s").tag("256")
                    Text("512 KB/s").tag("512")
                    Text("1 MB/s").tag("1024")
                }
            }

            Section("Cleanup") {
                Toggle("Delete torrent file after download", isOn: $draft.deleteTorrentAfterDownload)
                Toggle("Remove completed downloads after 7 days", isOn: $draft.autoRemoveCompleted)
            }
        }
        .formStyle(.grouped)
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
}

// MARK: - Playback

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
                Text("When off, playback continues if remux drops HDR mastering data; you may see a warning instead of an error. HDR badges only appear when metadata is verified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Transcode unsupported formats", isOn: $draft.allowTranscodeFallback)
                Text("Uses more CPU and disk. Converts VP9, AV1, DTS, and other codecs to Apple-friendly HLS via hardware encoding. HDR/Dolby badges are not shown for transcoded playback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Audio") {
                TextField("Preferred Language", text: $draft.preferredAudioLang, prompt: Text("en"))
                Text("Dolby Atmos and Spatial Audio use the verified surround bitstream from your file. On a receiver, enable Prefer HDMI Passthrough in System Settings → Sound. On AirPods Pro, turn on Spatial Audio in Control Center while playing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        }
        .formStyle(.grouped)
    }
}



// MARK: - Advanced

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

// MARK: - Draft

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
    var subtitleStyle = "cinematic"
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
    }
}
