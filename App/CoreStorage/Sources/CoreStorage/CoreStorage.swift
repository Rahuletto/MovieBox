import Foundation
import SwiftData

@Model
public final class MovieRecord {
    @Attribute(.unique) public var tmdbId: Int
    public var mediaKind: String
    public var title: String
    public var posterPath: String?
    public var genres: [Int]
    public var watchlistAddedAt: Date?
    public var lastWatchedAt: Date?
    public var playbackPositionSeconds: Double
    public var watchedFraction: Double
    /// Total runtime in seconds (from player when available).
    public var durationSeconds: Double
    /// Info hash of the last torrent streamed for this title (stable across indexer refreshes).
    public var lastStreamInfoHash: String?
    /// Last TV episode watched (0 = unknown).
    public var lastWatchedSeason: Int
    public var lastWatchedEpisode: Int

    public init(
        tmdbId: Int,
        mediaKind: String = "movie",
        title: String,
        posterPath: String? = nil,
        genres: [Int] = [],
        watchlistAddedAt: Date? = nil,
        lastWatchedAt: Date? = nil,
        playbackPositionSeconds: Double = 0,
        watchedFraction: Double = 0,
        durationSeconds: Double = 0,
        lastStreamInfoHash: String? = nil,
        lastWatchedSeason: Int = 0,
        lastWatchedEpisode: Int = 0
    ) {
        self.tmdbId = tmdbId
        self.mediaKind = mediaKind
        self.title = title
        self.posterPath = posterPath
        self.genres = genres
        self.watchlistAddedAt = watchlistAddedAt
        self.lastWatchedAt = lastWatchedAt
        self.playbackPositionSeconds = playbackPositionSeconds
        self.watchedFraction = watchedFraction
        self.durationSeconds = durationSeconds
        self.lastStreamInfoHash = lastStreamInfoHash
        self.lastWatchedSeason = lastWatchedSeason
        self.lastWatchedEpisode = lastWatchedEpisode
    }
}

@Model
public final class RatingRecord {
    @Attribute(.unique) public var tmdbId: Int
    public var rating: Float
    public var ratedAt: Date
    public var genres: [Int]

    public init(tmdbId: Int, rating: Float, ratedAt: Date = Date(), genres: [Int] = []) {
        self.tmdbId = tmdbId
        self.rating = rating
        self.ratedAt = ratedAt
        self.genres = genres
    }
}

@Model
public final class DownloadRecord {
    @Attribute(.unique) public var infoHash: String
    public var tmdbId: Int
    public var mediaKind: String
    public var title: String
    public var magnetURI: String
    public var quality: String
    public var hdrType: String?
    public var localFilePath: String?
    public var storageDirectory: String?
    public var state: String
    public var progressFraction: Double
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var pieceBitmap: Data
    public var createdAt: Date

    public init(
        infoHash: String,
        tmdbId: Int,
        mediaKind: String = "movie",
        title: String,
        magnetURI: String,
        quality: String,
        hdrType: String? = nil,
        localFilePath: String? = nil,
        storageDirectory: String? = nil,
        state: DownloadState = .queued,
        progressFraction: Double = 0,
        totalBytes: Int64 = 0,
        downloadedBytes: Int64 = 0,
        pieceBitmap: Data = Data(),
        createdAt: Date = Date()
    ) {
        self.infoHash = infoHash
        self.tmdbId = tmdbId
        self.mediaKind = mediaKind
        self.title = title
        self.magnetURI = magnetURI
        self.quality = quality
        self.hdrType = hdrType
        self.localFilePath = localFilePath
        self.storageDirectory = storageDirectory
        self.state = state.rawValue
        self.progressFraction = progressFraction
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.pieceBitmap = pieceBitmap
        self.createdAt = createdAt
    }
}

@Model
public final class AppSettings {
    public var proxyBaseURL: String
    /// When true, API calls use `http://127.0.0.1:8787` (wrangler dev) instead of `proxyBaseURL`.
    public var useLocalBackend: Bool
    public var appToken: String
    public var tmdbBearerToken: String
    public var omdbAPIKey: String
    public var defaultDownloadPath: String
    public var preferredQuality: String
    public var preferredAudioLang: String
    public var preferredSubtitleLang: String
    public var enableYTS: Bool
    /// Comma-separated indexer ids from backend `/api/config` (e.g. `torrentio,yts,1337x`).
    public var enabledTorrentIndexers: String = "torrentio,yts,eztv,piratebay,1337x,bitsearch,torrentdownload"
    public var enableSeeding: Bool
    public var maxActiveDownloads: Int
    public var maxActiveUploads: Int
    public var maxDownloadSpeedKBps: Int
    public var maxUploadSpeedKBps: Int
    public var deleteTorrentAfterDownload: Bool
    public var autoRemoveCompleted: Bool
    public var preferHDR: Bool
    /// When true, remux blocks playback if HDR/DV/Atmos metadata is stripped. Default off (warn and play).
    public var strictHDRValidation: Bool
    /// When true, FFmpeg hardware-transcodes unsupported codecs to HLS so more files play in AVPlayer.
    public var allowTranscodeFallback: Bool
    public var subtitlesEnabled: Bool
    public var subtitleStyle: String
    public var subtitleFontSize: Double
    public var audioFormatPriority: String
    public var resumePlayback: Bool
    public var fullScreenOnPlayback: Bool
    public var skipIntroDuration: Int
    public var onLaunchAction: String
    public var interfaceLanguage: String
    public var contentRegion: String
    public var posterSize: String
    public var backdropSize: String
    public var httpProxyURL: String
    public var useHTTPProxy: Bool
    public var requestTimeout: Int
    public var imageCacheSize: Int
    public var metadataCacheTTL: Int
    public var debugLogging: Bool
    public var logTorrentActivity: Bool

    public init(
        proxyBaseURL: String = "",
        useLocalBackend: Bool = false,
        appToken: String = "",
        tmdbBearerToken: String = "",
        omdbAPIKey: String = "",
        defaultDownloadPath: String = "",
        preferredQuality: String = "best",
        preferredAudioLang: String = "en",
        preferredSubtitleLang: String = "en",
        enableYTS: Bool = true,
        enabledTorrentIndexers: String = "torrentio,yts,eztv,piratebay,1337x,bitsearch,torrentdownload",
        enableSeeding: Bool = true,
        maxActiveDownloads: Int = 2,
        maxActiveUploads: Int = 5,
        maxDownloadSpeedKBps: Int = 0,
        maxUploadSpeedKBps: Int = 512,
        deleteTorrentAfterDownload: Bool = false,
        autoRemoveCompleted: Bool = false,
        preferHDR: Bool = true,
        strictHDRValidation: Bool = false,
        allowTranscodeFallback: Bool = true,
        subtitlesEnabled: Bool = true,
        subtitleStyle: String = "cinematic",
        subtitleFontSize: Double = 20,
        audioFormatPriority: String = "best",
        resumePlayback: Bool = true,
        fullScreenOnPlayback: Bool = false,
        skipIntroDuration: Int = 0,
        onLaunchAction: String = "home",
        interfaceLanguage: String = "",
        contentRegion: String = "US",
        posterSize: String = "w342",
        backdropSize: String = "w1280",
        httpProxyURL: String = "",
        useHTTPProxy: Bool = false,
        requestTimeout: Int = 20,
        imageCacheSize: Int = 250,
        metadataCacheTTL: Int = 60,
        debugLogging: Bool = false,
        logTorrentActivity: Bool = false
    ) {
        self.proxyBaseURL = proxyBaseURL
        self.useLocalBackend = useLocalBackend
        self.appToken = appToken
        self.tmdbBearerToken = tmdbBearerToken
        self.omdbAPIKey = omdbAPIKey
        self.defaultDownloadPath = defaultDownloadPath
        self.preferredQuality = preferredQuality
        self.preferredAudioLang = preferredAudioLang
        self.preferredSubtitleLang = preferredSubtitleLang
        self.enableYTS = enableYTS
        self.enabledTorrentIndexers = enabledTorrentIndexers
        self.enableSeeding = enableSeeding
        self.maxActiveDownloads = maxActiveDownloads
        self.maxActiveUploads = maxActiveUploads
        self.maxDownloadSpeedKBps = maxDownloadSpeedKBps
        self.maxUploadSpeedKBps = maxUploadSpeedKBps
        self.deleteTorrentAfterDownload = deleteTorrentAfterDownload
        self.autoRemoveCompleted = autoRemoveCompleted
        self.preferHDR = preferHDR
        self.strictHDRValidation = strictHDRValidation
        self.allowTranscodeFallback = allowTranscodeFallback
        self.subtitlesEnabled = subtitlesEnabled
        self.subtitleStyle = subtitleStyle
        self.subtitleFontSize = subtitleFontSize
        self.audioFormatPriority = audioFormatPriority
        self.resumePlayback = resumePlayback
        self.fullScreenOnPlayback = fullScreenOnPlayback
        self.skipIntroDuration = skipIntroDuration
        self.onLaunchAction = onLaunchAction
        self.interfaceLanguage = interfaceLanguage
        self.contentRegion = contentRegion
        self.posterSize = posterSize
        self.backdropSize = backdropSize
        self.httpProxyURL = httpProxyURL
        self.useHTTPProxy = useHTTPProxy
        self.requestTimeout = requestTimeout
        self.imageCacheSize = imageCacheSize
        self.metadataCacheTTL = metadataCacheTTL
        self.debugLogging = debugLogging
        self.logTorrentActivity = logTorrentActivity
    }
}

@Model
public final class SearchHistoryRecord {
    @Attribute(.unique) public var query: String
    public var searchedAt: Date

    public init(query: String, searchedAt: Date = Date()) {
        self.query = query
        self.searchedAt = searchedAt
    }
}

@Model
public final class SearchOpenedRecord {
    @Attribute(.unique) public var recordID: String
    public var tmdbId: Int
    public var mediaKind: String
    public var title: String
    public var posterPath: String?
    public var backdropPath: String?
    public var searchQuery: String
    public var openedAt: Date

    public init(
        tmdbId: Int,
        mediaKind: String,
        title: String,
        posterPath: String? = nil,
        backdropPath: String? = nil,
        searchQuery: String,
        openedAt: Date = Date()
    ) {
        self.recordID = Self.makeRecordID(tmdbId: tmdbId, mediaKind: mediaKind)
        self.tmdbId = tmdbId
        self.mediaKind = mediaKind
        self.title = title
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.searchQuery = searchQuery
        self.openedAt = openedAt
    }

    public static func makeRecordID(tmdbId: Int, mediaKind: String) -> String {
        "\(mediaKind)_\(tmdbId)"
    }
}

public enum DownloadState: String, Sendable, Codable, CaseIterable {
    case queued
    case downloading
    case paused
    case completed
    case failed
}

public enum MovieBoxSchema {
    public static let models: [any PersistentModel.Type] = [
        MovieRecord.self,
        RatingRecord.self,
        DownloadRecord.self,
        AppSettings.self,
        SearchHistoryRecord.self,
        SearchOpenedRecord.self
    ]
}

// MARK: - Model container

public enum MovieBoxModelContainer {
    private static let storeName = "MovieBox"

    /// Opens the shared SwiftData store, recreating it once if the on-disk schema is incompatible.
    public static func make(inMemoryOnly: Bool = false) throws -> ModelContainer {
        let schema = Schema(MovieBoxSchema.models)
        let storeURL = try persistentStoreURL()
        let config = ModelConfiguration(
            storeName,
            schema: schema,
            url: storeURL,
            allowsSave: !inMemoryOnly
        )

        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            guard !inMemoryOnly else { throw error }
            NSLog("MovieBox SwiftData: store incompatible (\(error)). Recreating \(storeURL.path)")
            try removeStoreFiles(at: storeURL)
            return try ModelContainer(for: schema, configurations: config)
        }
    }

    private static func persistentStoreURL() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw MovieBoxError.storage(NSError(domain: "MovieBox", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Application Support directory unavailable",
            ]))
        }
        let folder = support.appendingPathComponent("MovieBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(storeName).store", isDirectory: false)
    }

    private static func removeStoreFiles(at url: URL) throws {
        let fm = FileManager.default
        let paths = [url.path, url.path + "-shm", url.path + "-wal"]
        for path in paths where fm.fileExists(atPath: path) {
            try fm.removeItem(atPath: path)
        }
    }
}
