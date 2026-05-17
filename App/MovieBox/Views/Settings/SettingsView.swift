import AppKit
import CoreStorage
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsRows: [AppSettings]
    @State private var draft = SettingsDraft()

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
            Tab("Advanced", systemImage: "wrench.and.screwdriver") {
                AdvancedSettingsSection(draft: $draft)
            }
        }
        .scenePadding()
        .frame(width: 550)
        .onAppear { loadSettings() }
        .onChange(of: draft) { save() }
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
                TextField("Proxy Base URL", text: $draft.proxyBaseURL, prompt: Text("https://your-backend.workers.dev"))
                SecureField("App Token", text: $draft.appToken, prompt: Text("Enter token"))
                Text("When configured, all metadata requests route through your Hono backend.")
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

    var body: some View {
        Form {
            Section("Jackett") {
                SecureField("API Key", text: $draft.jackettAPIKey, prompt: Text("Enter key"))
                TextField("Host", text: $draft.jackettHost, prompt: Text("localhost"))
                TextField("Port", value: $draft.jackettPort, format: .number)
                Text("Both YTS and Jackett are searched automatically. Configure Jackett credentials to include additional indexers.")
                    .foregroundStyle(.secondary)
            }

            Section("Torrent Behavior") {
                Toggle("Seed after download completes", isOn: $draft.enableSeeding)
                Stepper("Max Active Downloads: \(draft.maxActiveDownloads)", value: $draft.maxActiveDownloads, in: 1...5)
                Stepper("Max Active Uploads: \(draft.maxActiveUploads)", value: $draft.maxActiveUploads, in: 1...10)
            }
        }
        .formStyle(.grouped)
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
                        TextField("", text: $draft.defaultDownloadPath)
                            .frame(maxWidth: 240)
                        Button("Choose…", action: chooseFolder)
                    }
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
        if panel.runModal() == .OK, let url = panel.url {
            draft.defaultDownloadPath = url.path
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
                TextField("Preferred Language", text: $draft.preferredSubtitleLang, prompt: Text("en"))
                Toggle("Enable subtitles by default", isOn: $draft.subtitlesEnabled)
                Picker("Subtitle Style", selection: $draft.subtitleStyle) {
                    Text("System Default").tag("system")
                    Text("Large White").tag("large-white")
                    Text("Yellow on Black").tag("yellow-black")
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
