import AppKit
import CoreStorage
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsRows: [AppSettings]
    @State private var draft = SettingsDraft()
    @State private var selection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)
        } detail: {
            Form {
                switch selection {
                case .general:
                    GeneralSettingsSection(draft: $draft, save: save)

                case .metadata:
                    MetadataSettingsSection(draft: $draft, save: save)

                case .torrent:
                    TorrentSettingsSection(draft: $draft, save: save)

                case .downloads:
                    DownloadSettingsSection(draft: $draft, save: save)

                case .playback:
                    PlaybackSettingsSection(draft: $draft, save: save)

                case .appearance:
                    AppearanceSettingsSection()

                case .advanced:
                    AdvancedSettingsSection(draft: $draft, save: save)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(selection.title)
            .frame(minWidth: 520)
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            loadSettings()
        }
    }

    private func loadSettings() {
        draft = SettingsDraft(settings: settingsRows.first)
    }

    private func save() {
        if let existing = settingsRows.first {
            draft.apply(to: existing)
        } else {
            let newSettings = AppSettings()
            draft.apply(to: newSettings)
            modelContext.insert(newSettings)
        }
        try? modelContext.save()
    }
}

// MARK: - General

private struct GeneralSettingsSection: View {
    @Binding var draft: SettingsDraft
    let save: () -> Void

    var body: some View {
        Section("Language") {
            Picker("Interface Language", selection: Binding(
                get: { draft.interfaceLanguage },
                set: { draft.interfaceLanguage = $0; save() }
            )) {
                Text("System Default").tag("")
                Text("English").tag("en")
                Text("Spanish").tag("es")
                Text("French").tag("fr")
                Text("German").tag("de")
                Text("Japanese").tag("ja")
            }
        }

        Section("Region") {
            Picker("Content Region", selection: Binding(
                get: { draft.contentRegion },
                set: { draft.contentRegion = $0; save() }
            )) {
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
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Metadata

private struct MetadataSettingsSection: View {
    @Binding var draft: SettingsDraft
    let save: () -> Void

    var body: some View {
        Section("Backend Proxy") {
            LabeledContent("Proxy Base URL") {
                TextField("https://your-backend.workers.dev", text: Binding(
                    get: { draft.proxyBaseURL },
                    set: { draft.proxyBaseURL = $0; save() }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
            }
            LabeledContent("App Token") {
                SecureField("Enter token", text: Binding(
                    get: { draft.appToken },
                    set: { draft.appToken = $0; save() }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
            }
            Text("When configured, all metadata requests route through your Hono backend.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Direct API Keys") {
            LabeledContent("TMDB Bearer Token") {
                SecureField("Enter token", text: Binding(
                    get: { draft.tmdbBearerToken },
                    set: { draft.tmdbBearerToken = $0; save() }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
            }
            LabeledContent("OMDb API Key") {
                SecureField("Enter key", text: Binding(
                    get: { draft.omdbAPIKey },
                    set: { draft.omdbAPIKey = $0; save() }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
            }
            Text("Used when no backend proxy is configured. TMDB is required for core functionality.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Image Quality") {
            Picker("Poster Size", selection: Binding(
                get: { draft.posterSize },
                set: { draft.posterSize = $0; save() }
            )) {
                Text("Small (185px)").tag("w185")
                Text("Medium (342px)").tag("w342")
                Text("Large (500px)").tag("w500")
                Text("Original").tag("original")
            }
            Picker("Backdrop Size", selection: Binding(
                get: { draft.backdropSize },
                set: { draft.backdropSize = $0; save() }
            )) {
                Text("Medium (780px)").tag("w780")
                Text("Large (1280px)").tag("w1280")
                Text("Original").tag("original")
            }
        }
    }
}

// MARK: - Torrent

private struct TorrentSettingsSection: View {
    @Binding var draft: SettingsDraft
    let save: () -> Void

    var body: some View {
        Section("YTS") {
            Toggle("Enable YTS Search", isOn: Binding(
                get: { draft.enableYTS },
                set: { draft.enableYTS = $0; save() }
            ))
            Text("YTS provides public domain and open-license movie torrents.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Jackett") {
            Toggle("Enable Jackett", isOn: Binding(
                get: { draft.enableJackett },
                set: { draft.enableJackett = $0; save() }
            ))
            LabeledContent("API Key") {
                SecureField("Enter key", text: Binding(
                    get: { draft.jackettAPIKey },
                    set: { draft.jackettAPIKey = $0; save() }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .disabled(!draft.enableJackett)
            }
            LabeledContent("Host") {
                TextField("localhost", text: Binding(
                    get: { draft.jackettHost },
                    set: { draft.jackettHost = $0; save() }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .disabled(!draft.enableJackett)
            }
            LabeledContent("Port") {
                TextField("9117", value: Binding(
                    get: { draft.jackettPort },
                    set: { draft.jackettPort = $0; save() }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 100)
                .disabled(!draft.enableJackett)
            }
            Text("Jackett aggregates results from multiple torrent indexers.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Torrent Behavior") {
            Toggle("Seed after download completes", isOn: Binding(
                get: { draft.enableSeeding },
                set: { draft.enableSeeding = $0; save() }
            ))
            Stepper("Max Active Downloads: \(draft.maxActiveDownloads)", value: Binding(
                get: { draft.maxActiveDownloads },
                set: { draft.maxActiveDownloads = $0; save() }
            ), in: 1...5)
            Stepper("Max Active Uploads: \(draft.maxActiveUploads)", value: Binding(
                get: { draft.maxActiveUploads },
                set: { draft.maxActiveUploads = $0; save() }
            ), in: 1...10)
        }
    }
}

// MARK: - Downloads

private struct DownloadSettingsSection: View {
    @Binding var draft: SettingsDraft
    let save: () -> Void

    var body: some View {
        Section("Location") {
            LabeledContent("Download Folder") {
                HStack {
                    TextField("", text: Binding(
                        get: { draft.defaultDownloadPath },
                        set: { draft.defaultDownloadPath = $0; save() }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                    Button("Choose...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            draft.defaultDownloadPath = url.path
                            save()
                        }
                    }
                }
            }
        }

        Section("Speed Limits") {
            Picker("Download Speed", selection: Binding(
                get: { draft.downloadSpeedLimit },
                set: { draft.downloadSpeedLimit = $0; save() }
            )) {
                Text("Unlimited").tag("0")
                Text("1 MB/s").tag("1024")
                Text("5 MB/s").tag("5120")
                Text("10 MB/s").tag("10240")
                Text("25 MB/s").tag("25600")
            }
            Picker("Upload Speed", selection: Binding(
                get: { draft.uploadSpeedLimit },
                set: { draft.uploadSpeedLimit = $0; save() }
            )) {
                Text("Unlimited").tag("0")
                Text("128 KB/s").tag("128")
                Text("256 KB/s").tag("256")
                Text("512 KB/s").tag("512")
                Text("1 MB/s").tag("1024")
            }
        }

        Section("Cleanup") {
            Toggle("Delete torrent file after download", isOn: Binding(
                get: { draft.deleteTorrentAfterDownload },
                set: { draft.deleteTorrentAfterDownload = $0; save() }
            ))
            Toggle("Remove completed downloads after 7 days", isOn: Binding(
                get: { draft.autoRemoveCompleted },
                set: { draft.autoRemoveCompleted = $0; save() }
            ))
        }
    }
}

// MARK: - Playback

private struct PlaybackSettingsSection: View {
    @Binding var draft: SettingsDraft
    let save: () -> Void

    var body: some View {
        Section("Quality") {
            Picker("Preferred Quality", selection: Binding(
                get: { draft.preferredQuality },
                set: { draft.preferredQuality = $0; save() }
            )) {
                Text("Best Available").tag("best")
                Text("4K (2160p)").tag("4k")
                Text("1080p").tag("1080p")
                Text("720p").tag("720p")
            }
            Toggle("Prefer HDR when available", isOn: Binding(
                get: { draft.preferHDR },
                set: { draft.preferHDR = $0; save() }
            ))
        }

        Section("Audio") {
            LabeledContent("Preferred Language") {
                TextField("en", text: Binding(
                    get: { draft.preferredAudioLang },
                    set: { draft.preferredAudioLang = $0; save() }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 80)
            }
            Picker("Audio Format Priority", selection: Binding(
                get: { draft.audioFormatPriority },
                set: { draft.audioFormatPriority = $0; save() }
            )) {
                Text("Best Available").tag("best")
                Text("Dolby Atmos").tag("atmos")
                Text("DTS-HD").tag("dtshd")
                Text("TrueHD").tag("truehd")
                Text("EAC3").tag("eac3")
                Text("AAC").tag("aac")
            }
        }

        Section("Subtitles") {
            LabeledContent("Preferred Language") {
                TextField("en", text: Binding(
                    get: { draft.preferredSubtitleLang },
                    set: { draft.preferredSubtitleLang = $0; save() }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 80)
            }
            Toggle("Enable subtitles by default", isOn: Binding(
                get: { draft.subtitlesEnabled },
                set: { draft.subtitlesEnabled = $0; save() }
            ))
            Picker("Subtitle Style", selection: Binding(
                get: { draft.subtitleStyle },
                set: { draft.subtitleStyle = $0; save() }
            )) {
                Text("System Default").tag("system")
                Text("Large White").tag("large-white")
                Text("Yellow on Black").tag("yellow-black")
            }
        }

        Section("Player Behavior") {
            Toggle("Resume playback from last position", isOn: Binding(
                get: { draft.resumePlayback },
                set: { draft.resumePlayback = $0; save() }
            ))
            Toggle("Enter full screen on playback", isOn: Binding(
                get: { draft.fullScreenOnPlayback },
                set: { draft.fullScreenOnPlayback = $0; save() }
            ))
            Stepper("Skip intro duration: \(draft.skipIntroDuration)s", value: Binding(
                get: { draft.skipIntroDuration },
                set: { draft.skipIntroDuration = $0; save() }
            ), in: 0...30)
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsSection: View {
    var body: some View {
        Section("Theme") {
            Picker("Appearance", selection: .constant("system")) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
            Text("MovieBox adapts to your system appearance automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Content Display") {
            Picker("Poster Aspect Ratio", selection: .constant("poster")) {
                Text("Poster (2:3)").tag("poster")
                Text("Square (1:1)").tag("square")
                Text("Landscape (16:9)").tag("landscape")
            }
        }
    }
}

// MARK: - Advanced

private struct AdvancedSettingsSection: View {
    @Binding var draft: SettingsDraft
    let save: () -> Void

    var body: some View {
        Section("Network") {
            LabeledContent("HTTP Proxy URL") {
                TextField("http://proxy:port", text: Binding(
                    get: { draft.httpProxyURL },
                    set: { draft.httpProxyURL = $0; save() }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
            }
            Toggle("Use HTTP proxy for all requests", isOn: Binding(
                get: { draft.useHTTPProxy },
                set: { draft.useHTTPProxy = $0; save() }
            ))
            .disabled(draft.httpProxyURL.isEmpty)
            Stepper("Request Timeout: \(draft.requestTimeout)s", value: Binding(
                get: { draft.requestTimeout },
                set: { draft.requestTimeout = $0; save() }
            ), in: 5...60)
        }

        Section("Cache") {
            Stepper("Image Cache Size: \(draft.imageCacheSize) MB", value: Binding(
                get: { draft.imageCacheSize },
                set: { draft.imageCacheSize = $0; save() }
            ), in: 50...500, step: 50)
            Stepper("Metadata Cache TTL: \(draft.metadataCacheTTL) min", value: Binding(
                get: { draft.metadataCacheTTL },
                set: { draft.metadataCacheTTL = $0; save() }
            ), in: 5...1440, step: 5)
        }

        Section("Logging") {
            Toggle("Enable debug logging", isOn: Binding(
                get: { draft.debugLogging },
                set: { draft.debugLogging = $0; save() }
            ))
            Toggle("Log torrent activity", isOn: Binding(
                get: { draft.logTorrentActivity },
                set: { draft.logTorrentActivity = $0; save() }
            ))
        }
    }
}

// MARK: - Sections

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case metadata
    case torrent
    case downloads
    case playback
    case appearance
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .metadata: "Metadata"
        case .torrent: "Torrents"
        case .downloads: "Downloads"
        case .playback: "Playback"
        case .appearance: "Appearance"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gear"
        case .metadata: "key"
        case .torrent: "point.3.connected.trianglepath.dotted"
        case .downloads: "arrow.down.circle"
        case .playback: "play.rectangle"
        case .appearance: "paintpalette"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

// MARK: - Draft

private struct SettingsDraft {
    var proxyBaseURL = ""
    var appToken = ""
    var tmdbBearerToken = ""
    var omdbAPIKey = ""
    var jackettAPIKey = ""
    var jackettHost = "localhost"
    var jackettPort = 9117
    var defaultDownloadPath = "~/Movies/MovieBox"
    var preferredQuality = "best"
    var preferredAudioLang = "en"
    var preferredSubtitleLang = "en"
    var enableJackett = false
    var enableYTS = true
    var enableSeeding = true
    var maxActiveDownloads = 2
    var maxActiveUploads = 5
    var downloadSpeedLimit = "0"
    var uploadSpeedLimit = "0"
    var deleteTorrentAfterDownload = false
    var autoRemoveCompleted = false
    var preferHDR = true
    var subtitlesEnabled = true
    var subtitleStyle = "system"
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
        appToken = settings.appToken
        tmdbBearerToken = settings.tmdbBearerToken
        omdbAPIKey = settings.omdbAPIKey
        jackettAPIKey = settings.jackettAPIKey
        jackettHost = settings.jackettHost
        jackettPort = settings.jackettPort
        defaultDownloadPath = settings.defaultDownloadPath
        preferredQuality = settings.preferredQuality
        preferredAudioLang = settings.preferredAudioLang
        preferredSubtitleLang = settings.preferredSubtitleLang
        enableJackett = settings.enableJackett
        enableYTS = settings.enableYTS
        enableSeeding = settings.enableSeeding
        maxActiveDownloads = settings.maxActiveDownloads
        maxActiveUploads = settings.maxActiveUploads
        downloadSpeedLimit = String(settings.maxDownloadSpeedKBps)
        uploadSpeedLimit = String(settings.maxUploadSpeedKBps)
        deleteTorrentAfterDownload = settings.deleteTorrentAfterDownload
        autoRemoveCompleted = settings.autoRemoveCompleted
        preferHDR = settings.preferHDR
        subtitlesEnabled = settings.subtitlesEnabled
        subtitleStyle = settings.subtitleStyle
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
        settings.appToken = appToken
        settings.tmdbBearerToken = tmdbBearerToken
        settings.omdbAPIKey = omdbAPIKey
        settings.jackettAPIKey = jackettAPIKey
        settings.jackettHost = jackettHost
        settings.jackettPort = jackettPort
        settings.defaultDownloadPath = defaultDownloadPath
        settings.preferredQuality = preferredQuality
        settings.preferredAudioLang = preferredAudioLang
        settings.preferredSubtitleLang = preferredSubtitleLang
        settings.enableJackett = enableJackett
        settings.enableYTS = enableYTS
        settings.enableSeeding = enableSeeding
        settings.maxActiveDownloads = maxActiveDownloads
        settings.maxActiveUploads = maxActiveUploads
        settings.maxDownloadSpeedKBps = Int(downloadSpeedLimit) ?? 0
        settings.maxUploadSpeedKBps = Int(uploadSpeedLimit) ?? 0
        settings.deleteTorrentAfterDownload = deleteTorrentAfterDownload
        settings.autoRemoveCompleted = autoRemoveCompleted
        settings.preferHDR = preferHDR
        settings.subtitlesEnabled = subtitlesEnabled
        settings.subtitleStyle = subtitleStyle
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
