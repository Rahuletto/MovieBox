import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import SwiftUI

public enum PlayerHDRType: String, Sendable, Codable {
    case hdr = "HDR"
    case hdr10 = "HDR10"
    case hdr10Plus = "HDR10+"
    case dolbyVision = "Dolby Vision"
    case dolbyVisionWithHDR10 = "DV-HDR10"
}

public struct PlayerEpisode: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let episodeNumber: Int
    public let seasonNumber: Int
    public let url: URL
    public let subtitleURL: URL?
    
    public init(id: String, title: String, episodeNumber: Int, seasonNumber: Int, url: URL, subtitleURL: URL? = nil) {
        self.id = id
        self.title = title
        self.episodeNumber = episodeNumber
        self.seasonNumber = seasonNumber
        self.url = url
        self.subtitleURL = subtitleURL
    }
}

@MainActor
@Observable
public final class PlayerState {
    /// Matches CoreStreaming `TorrentPlaybackURLScheme` (CorePlayer cannot import CoreStreaming).
    private static func isTorrentResourceLoaderURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "mbtorrenthttps" || scheme == "mbtorrent"
    }

    public var player: AVPlayer
    public var title: String
    public var seriesName: String = ""
    public var episodeTitle: String? = nil
    public var videoGravity: AVLayerVideoGravity = .resizeAspect
    public var movieId: Int
    public var isPresented: Bool
    /// True when the player was opened for a torrent stream (not trailer/clip-only).
    public var isStreamingTorrent: Bool = false
    /// Full-screen player chrome is hidden while playback continues (e.g. PiP + browsing).
    public var isPlaybackChromeHidden: Bool = false
    /// When true, closing PiP (X) dismisses playback instead of restoring the in-app player.
    fileprivate var dismissPlaybackWhenPiPCloses: Bool = false
    /// Fades the player layer in after app chrome has faded out.
    public var isPlayerRevealed: Bool
    public var isPlaying: Bool
    /// True while AVPlayer is waiting for media data (initial load or rebuffer).
    public var isBuffering: Bool = false
    /// Shown under the buffering spinner while the torrent stream is preparing.
    public var bufferingDetail: String?
    public var currentTime: Double = 0
    public var duration: Double = 0
    public var bufferedTimeRanges: [ClosedRange<Double>] = []
    public var volume: Float = 1.0
    public var isMuted: Bool = false
    public var playbackRate: Double = 1.0
    public private(set) var isFastScanning = false
    /// Fast scan or transient video-fit feedback (top-center glass pill).
    public var hudStatusPill: PlayerHUDStatusPillModel?
    public var showsControls: Bool = false
    public var subtitleURL: URL? = nil
    public var activeSubtitleTrack: Int = 0
    public var currentSubtitleText: String = ""
    public var currentSubtitleCueID: UUID?
    public var subtitleAppearance: SubtitleAppearance = .cinematic
    public var subtitleFontSize: CGFloat = 20
    
    public var hdrType: PlayerHDRType? = nil
    public var audioFormat: PlayerAudioFormat? = nil
    public var errorMessage: String? = nil
    public var onPositionUpdate: ((Int, Double, Double) -> Void)?

    // Torrent / quality source picker
    public var playbackSources: [PlaybackSourceOption] = []
    public var selectedPlaybackSourceID: String?
    public var isSwitchingSource = false
    public var onSelectPlaybackSource: (@MainActor (PlaybackSourceOption) async -> Void)?

    public var hasMultiplePlaybackSources: Bool {
        playbackSources.count > 1
    }
    
    // TV Series Episode Listing
    public var episodes: [PlayerEpisode] = []
    public var currentEpisodeIndex: Int? = nil
    public var isEpisodesSidebarOpen: Bool = false
    public var isSourcesSidebarOpen: Bool = false
    public var isSubtitlesSidebarOpen: Bool = false
    public var availableSubtitles: [PlayerSubtitleOption] = []
    public var selectedSubtitleID: String?
    public var isLoadingSubtitleCatalog: Bool = false
    public var onSelectSubtitle: (@MainActor (PlayerSubtitleOption) async -> Void)?
    public var onRefreshSubtitles: (@MainActor () async -> Void)?
    /// Seek here once the item is `readyToPlay` (continue watching).
    public var pendingResumePosition: Double?

    // Picture in Picture
    public var isPictureInPictureActive: Bool = false
    public var isPictureInPicturePossible: Bool = false
    private var pipController: AVPictureInPictureController?
    private var pipDelegate: PlayerPiPDelegate?
    private var fastScanBackwardTask: Task<Void, Never>?
    private var fastScanIsForward = false
    private var wasPlayingBeforeFastScan = false
    private var hudPillDismissTask: Task<Void, Never>?
    private var hudPillDismissGeneration: UInt64 = 0
    private var qualityBadgePillShownForCurrentItem = false

    private var timeObserver: Any?
    private var itemStatusObserver: NSKeyValueObservation?
    private var playbackBufferObserver: NSKeyValueObservation?
    private var presentationSizeObserver: NSKeyValueObservation?
    private var playbackEndObserver: NSObjectProtocol?
    private var thumbnailService: ThumbnailService?
    private var subtitleStream: SubtitleStream?
    private var subtitleLoadTask: Task<Void, Never>?
    private var subtitleUpdateTask: Task<Void, Never>?
    private var cancellables: [AnyCancellable] = []
    private var observedPlayerItem: AVPlayerItem?

    private var lastPositionReportTime: Date = .distantPast
    private var lastReportedPosition: Double = -1
    private var lastSubtitleSyncTime: Double = -1

    private var previousWindowFrame: NSRect? = nil
    private var hasResizedForCurrentVideo = false
    private var presentationTransitionTask: Task<Void, Never>?
    private var lastPlaybackLoad: StoredPlaybackLoad?
    private var streamsFromLocalTorrentServer = false

    private struct StoredPlaybackLoad: Sendable {
        let url: URL
        let title: String
        let movieId: Int
        let subtitleURL: URL?
        let hdrType: PlayerHDRType?
        let audioFormat: PlayerAudioFormat?
        let subtitleAppearance: SubtitleAppearance
        let subtitleFontSize: CGFloat
        let episodeTitle: String?
        let episodes: [PlayerEpisode]
        let currentEpisodeIndex: Int?
        let displayTitle: String?
        let resumePosition: Double?
    }

    private static let positionReportInterval: TimeInterval = 5
    private static let positionReportMinimumDelta: Double = 8
    private static let timeObserverInterval: TimeInterval = 0.25
    private static let subtitleSyncInterval: TimeInterval = 0.2

    public init(player: AVPlayer = AVPlayer(), title: String = "", movieId: Int = 0, isPresented: Bool = false) {
        self.player = player
        self.title = title
        self.movieId = movieId
        self.isPresented = isPresented
        self.isPlayerRevealed = false
        self.isPlaying = false
        self.currentTime = 0
        self.duration = 0
        self.bufferedTimeRanges = []
        self.volume = 1.0
        self.isMuted = false
        self.playbackRate = 1.0
        self.showsControls = true
        self.subtitleURL = nil
        self.activeSubtitleTrack = -1
        self.hdrType = nil
        self.audioFormat = nil
    }

    /// Opens the player immediately and shows buffering until `load(url:)` is called.
    public func beginBufferingPlayback(
        title: String,
        movieId: Int,
        subtitleAppearance: SubtitleAppearance = .cinematic,
        subtitleFontSize: CGFloat = 20,
        episodeTitle: String? = nil,
        displayTitle: String? = nil
    ) {
        errorMessage = nil
        isBuffering = true
        bufferingDetail = "Preparing stream…"
        self.title = title
        self.movieId = movieId
        self.subtitleAppearance = subtitleAppearance
        self.subtitleFontSize = subtitleFontSize

        let hudTitle: String
        if let displayTitle, !displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hudTitle = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            hudTitle = PlayerState.parseTVShowMetadata(from: title).seriesName
        }
        seriesName = hudTitle
        self.episodeTitle = episodeTitle

        showsControls = true
        isPresented = true
        isPlayerRevealed = true
        isPlaying = false
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    public func updateBufferingDetail(_ text: String?) {
        bufferingDetail = text
        if text != nil {
            isBuffering = true
        }
    }

    public func load(
        url: URL,
        title: String,
        movieId: Int = 0,
        subtitleURL: URL? = nil,
        hdrType: PlayerHDRType? = nil,
        audioFormat: PlayerAudioFormat? = nil,
        subtitleAppearance: SubtitleAppearance = .cinematic,
        subtitleFontSize: CGFloat = 20,
        episodeTitle: String? = nil,
        episodes: [PlayerEpisode] = [],
        currentEpisodeIndex: Int? = nil,
        displayTitle: String? = nil,
        resumePosition: Double? = nil,
        knownDurationSeconds: Double? = nil,
        resourceLoaderDelegate: AVAssetResourceLoaderDelegate? = nil,
        resourceLoaderQueue: DispatchQueue? = nil
    ) {
        stopPlaybackResources()

        streamsFromLocalTorrentServer =
            Self.isTorrentResourceLoaderURL(url)
            || url.host.map { $0 == "127.0.0.1" || $0 == "localhost" } == true

        self.title = title
        self.movieId = movieId
        self.subtitleURL = subtitleURL
        self.hdrType = hdrType
        self.audioFormat = audioFormat
        self.subtitleAppearance = subtitleAppearance
        qualityBadgePillShownForCurrentItem = false
        self.subtitleFontSize = subtitleFontSize
        self.errorMessage = nil
        if !episodes.isEmpty {
            self.episodes = episodes
            self.currentEpisodeIndex = currentEpisodeIndex
        }
        
        self.videoGravity = .resizeAspect // Reset to default
        hasResizedForCurrentVideo = false

        let hudTitle: String
        if let displayTitle, !displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hudTitle = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let ep = episodeTitle {
            let parsed = PlayerState.parseTVShowMetadata(from: title)
            hudTitle = parsed.seriesName
        } else {
            let parsed = PlayerState.parseTVShowMetadata(from: title)
            hudTitle = parsed.episodeName == nil ? parsed.seriesName : parsed.seriesName
        }

        if let ep = episodeTitle {
            self.seriesName = hudTitle
            self.episodeTitle = ep
        } else {
            self.seriesName = hudTitle
            self.episodeTitle = nil
        }

        if let resumePosition, resumePosition > 20 {
            pendingResumePosition = resumePosition
        } else {
            pendingResumePosition = nil
        }

        if let knownDurationSeconds, knownDurationSeconds.isFinite, knownDurationSeconds > 0 {
            duration = knownDurationSeconds
        } else {
            duration = 0
        }
        currentTime = 0

        lastPositionReportTime = .distantPast
        lastReportedPosition = -1
        lastSubtitleSyncTime = -1
        isBuffering = true

        let isTorrentCustomScheme = Self.isTorrentResourceLoaderURL(url)
        var assetOptions: [String: Any] = [
            AVURLAssetAllowsExpensiveNetworkAccessKey: true,
            AVURLAssetAllowsCellularAccessKey: true,
            AVURLAssetAllowsConstrainedNetworkAccessKey: true,
            // Avoid blocking the main thread probing duration on large torrent streams.
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
        ]
        if !isTorrentCustomScheme {
            var headers: [String: String] = [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            ]
            if url.host?.contains("piped") == true || url.host?.contains("googlevideo.com") == true {
                let referer = url.scheme ?? "https" + "://" + (url.host ?? "youtube.com")
                headers["Referer"] = referer
            }
            assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }

        let asset = AVURLAsset(url: url, options: assetOptions)
        if let resourceLoaderDelegate {
            let queue = resourceLoaderQueue
                ?? DispatchQueue(label: "com.marban.moviebox.torrent-resource-loader")
            asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: queue)
            if isTorrentCustomScheme {
                PlaybackLog.log("load mbtorrent — resource loader delegate attached host=\(url.host ?? "?")")
            }
        } else if isTorrentCustomScheme {
            PlaybackLog.log("load mbtorrent URL without resource loader delegate — playback will fail host=\(url.host ?? "?")")
        }
        if let existing = thumbnailService {
            Task { await existing.clearCache() }
        }
        thumbnailService = ThumbnailService(asset: asset)

        PlaybackLog.log("load url=\(PlaybackLog.redactURL(url)) title=\(title) movieId=\(movieId)")

        lastPlaybackLoad = StoredPlaybackLoad(
            url: url,
            title: title,
            movieId: movieId,
            subtitleURL: subtitleURL,
            hdrType: hdrType,
            audioFormat: audioFormat,
            subtitleAppearance: subtitleAppearance,
            subtitleFontSize: subtitleFontSize,
            episodeTitle: episodeTitle,
            episodes: episodes,
            currentEpisodeIndex: currentEpisodeIndex,
            displayTitle: displayTitle,
            resumePosition: resumePosition
        )

        let playerItem = AVPlayerItem(asset: asset)
        if player.currentItem == nil {
            player = AVPlayer(playerItem: playerItem)
        } else {
            player.replaceCurrentItem(with: playerItem)
        }
        player.volume = volume
        player.isMuted = isMuted

        if subtitleURL != nil {
            disableEmbeddedCaptions(on: playerItem, asset: asset)
        }

        showsControls = true

        schedulePlaybackStart(
            url: url,
            subtitleURL: subtitleURL,
            useTransition: !(isPresented && isPlayerRevealed)
        )
    }

    private func schedulePlaybackStart(url: URL, subtitleURL: URL?, useTransition: Bool) {
        let work = { [weak self] in
            guard let self else { return }
            if useTransition, !(self.isPresented && self.isPlayerRevealed) {
                PlaybackLog.log("revealPlayerWithTransition → will play after fade")
                self.revealPlayerWithTransition {
                    self.startPlayback(subtitleURL: subtitleURL)
                }
            } else {
                PlaybackLog.log("play() immediately (player already visible)")
                self.startPlayback(subtitleURL: subtitleURL)
            }
        }
        DispatchQueue.main.async(execute: work)
    }

    private func startPlayback(subtitleURL: URL?) {
        setupObservers()
        if let subtitleURL {
            loadSubtitleStream(from: subtitleURL)
        } else {
            cancelSubtitleWork()
        }
        player.play()
        player.rate = Float(playbackRate)
        isPlaying = true
    }

    private func revealPlayerWithTransition(onRevealed: @escaping () -> Void) {
        presentationTransitionTask?.cancel()
        presentationTransitionTask = Task { @MainActor in
            await Task.yield()
            isPresented = true
            isPlayerRevealed = false
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.38)) {
                isPlayerRevealed = true
            }
            onRevealed()
        }
    }

    static func playbackFailureMessage(from error: Error?) -> String {
        guard let error else {
            return "Playback failed. Try another version or format."
        }
        let ns = error as NSError
        PlaybackLog.log(
            "AVPlayerItem NSError domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)"
        )
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            PlaybackLog.log(
                "AVPlayerItem underlying domain=\(underlying.domain) code=\(underlying.code) desc=\(underlying.localizedDescription)"
            )
            if underlying.domain == NSOSStatusErrorDomain, underlying.code == -12935 {
                return "This file cannot be streamed yet — the torrent buffer was incomplete or corrupt. Wait for more buffering or try another release."
            }
            let underlyingText = underlying.localizedDescription.lowercased()
            if underlying.code == -16849 || underlyingText.contains("503") || underlyingText.contains("service unavailable") {
                return "The torrent has not buffered that part of the file yet. Leave the download running, then tap play again — it does not recover by itself on this screen."
            }
            if underlying.domain == "CoreMediaErrorDomain", underlying.code == -12939 {
                return "The local stream’s HTTP response did not match the byte range AVPlayer requested. Rebuild with the latest app and try again; if it persists, leave the torrent buffering longer before Retry."
            }
        }
        if ns.domain == AVFoundationErrorDomain, ns.code == -11828 {
            return "The player could not read the stream (often incomplete MKV/MP4 index or a bad range response). This is not “unsupported format.” Buffer more — especially the end of the file — then tap play again."
        }
        let trimmed = ns.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "unknown error" {
            if ns.domain == NSURLErrorDomain, ns.code == -1 {
                return "Playback failed — the stream was not ready (container index or buffer missing). Wait for buffering to finish, then tap Retry."
            }
            return "Playback failed (error \(ns.code)). Try another version or format."
        }
        return trimmed
    }

    public static func parseTVShowMetadata(from rawTitle: String) -> (seriesName: String, episodeName: String?) {
        let patterns = [
            #"(.*)\.[Ss](\d+)[Ee](\d+)"#,           // Show.Name.S01E01
            #"(.*)\s-\s[Ss](\d+)[Ee](\d+)"#,         // Show Name - S01E01
            #"(.*)\s-\s(\d+)x(\d+)"#,               // Show Name - 1x01
            #"(.*)\s[Ss](\d+)[Ee](\d+)"#,            // Show Name S01E01
            #"(.*)\sSeason\s(\d+)\sEpisode\s(\d+)"# // Show Name Season 1 Episode 1
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: rawTitle, options: [], range: NSRange(rawTitle.startIndex..., in: rawTitle)) {
                
                if match.numberOfRanges >= 4,
                   let seriesRange = Range(match.range(at: 1), in: rawTitle),
                   let seasonRange = Range(match.range(at: 2), in: rawTitle),
                   let episodeRange = Range(match.range(at: 3), in: rawTitle) {
                    
                    let rawSeries = String(rawTitle[seriesRange])
                    let cleanedSeries = rawSeries.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    let seasonStr = String(rawTitle[seasonRange])
                    let episodeStr = String(rawTitle[episodeRange])
                    
                    let formattedEpisode = "S\(seasonStr)E\(episodeStr)"
                    return (cleanedSeries, formattedEpisode)
                }
            }
        }
        
        // Return cleaned movie/title
        let cleanedTitle = rawTitle.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleanedTitle, nil)
    }

    public func cycleVideoGravity() {
        if videoGravity == .resizeAspect {
            videoGravity = .resizeAspectFill
        } else if videoGravity == .resizeAspectFill {
            videoGravity = .resize
        } else {
            videoGravity = .resizeAspect
        }
        guard !isFastScanning else { return }
        presentVideoGravityHUDPill()
    }

    private func cancelHUDPillDismissTask() {
        hudPillDismissTask?.cancel()
        hudPillDismissTask = nil
    }

    private func setHUDStatusPill(_ pill: PlayerHUDStatusPillModel?) {
        withAnimation(.playerHUDStatusPill) {
            hudStatusPill = pill
        }
    }

    private func presentVideoGravityHUDPill() {
        presentTransientHUDPill(.videoGravity(title: videoGravityHUDTitle, icon: "aspectratio")) { pill in
            if case .videoGravity = pill { return true }
            return false
        }
    }

    private func presentPlaybackRateHUDPill() {
        presentTransientHUDPill(.playbackRate(rate: playbackRate)) { pill in
            if case .playbackRate = pill { return true }
            return false
        }
    }

    private func presentQualityBadgesHUDPillIfNeeded() {
        guard !qualityBadgePillShownForCurrentItem, !isFastScanning else { return }
        let kinds = qualityBadgeKinds
        guard !kinds.isEmpty else { return }
        qualityBadgePillShownForCurrentItem = true
        presentTransientHUDPill(
            .qualityBadges(kinds: kinds),
            dismissAfter: 5
        ) { pill in
            if case .qualityBadges = pill { return true }
            return false
        }
    }

    private func presentTransientHUDPill(
        _ pill: PlayerHUDStatusPillModel,
        dismissAfter seconds: TimeInterval = 2,
        shouldDismiss: @escaping (PlayerHUDStatusPillModel) -> Bool
    ) {
        cancelHUDPillDismissTask()
        hudPillDismissGeneration += 1
        let generation = hudPillDismissGeneration
        setHUDStatusPill(pill)
        hudPillDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            guard self.hudPillDismissGeneration == generation else { return }
            if let current = self.hudStatusPill, shouldDismiss(current) {
                self.setHUDStatusPill(nil)
            }
        }
    }

    public var videoGravityHUDTitle: String {
        switch videoGravity {
        case .resizeAspect: return "Fit Screen"
        case .resizeAspectFill: return "Fill"
        case .resize: return "100%"
        default: return "Fit Screen"
        }
    }

    public var videoGravityLabel: String {
        switch videoGravity {
        case .resizeAspect: return "Fit"
        case .resizeAspectFill: return "Fill"
        case .resize: return "100%"
        default: return "Fit"
        }
    }

    /// Applies live Settings changes while playback is active.
    public func applyPlaybackSettings(
        subtitleStyle: String,
        subtitlesEnabled: Bool,
        subtitleFontSize: Double = 20
    ) {
        subtitleAppearance = SubtitleAppearance.from(settingsValue: subtitleStyle)
        self.subtitleFontSize = CGFloat(subtitleFontSize)

        if !subtitlesEnabled {
            if activeSubtitleTrack >= 0 {
                activeSubtitleTrack = -1
                currentSubtitleText = ""
                currentSubtitleCueID = nil
            }
            return
        }

        guard subtitleURL != nil else { return }

        if subtitleStream != nil {
            if activeSubtitleTrack < 0 {
                activeSubtitleTrack = 0
            }
            updateSubtitle(at: currentTime, force: true)
        } else if let url = subtitleURL {
            loadSubtitleStream(from: url)
        }
    }

    private func disableEmbeddedCaptions(on playerItem: AVPlayerItem, asset: AVURLAsset) {
        Task { [weak self] in
            guard let group = try? await asset.loadMediaSelectionGroup(for: .legible) else { return }
            await MainActor.run { [weak self] in
                guard let self, playerItem === self.observedPlayerItem else { return }
                playerItem.select(nil, in: group)
            }
        }
    }

    public func loadSubtitleStream(from url: URL) {
        subtitleURL = url
        subtitleLoadTask?.cancel()
        subtitleUpdateTask?.cancel()
        subtitleStream = nil
        subtitleLoadTask = Task { @MainActor in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }
                let stream = SubtitleStream()
                await stream.load(from: data)
                guard !Task.isCancelled else { return }
                subtitleStream = stream
                activeSubtitleTrack = 0
                lastSubtitleSyncTime = -1
                updateSubtitle(at: currentTime, force: true)
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("Failed to load subtitle stream: \(error)")
            }
        }
    }

    public func toggleSubtitle() {
        setSubtitlesEnabled(activeSubtitleTrack < 0)
    }

    public func setSubtitlesEnabled(_ enabled: Bool) {
        if enabled {
            if subtitleURL != nil {
                if subtitleStream == nil, let url = subtitleURL {
                    loadSubtitleStream(from: url)
                } else {
                    activeSubtitleTrack = 0
                    updateSubtitle(at: currentTime, force: true)
                }
            }
        } else {
            activeSubtitleTrack = -1
            currentSubtitleText = ""
            currentSubtitleCueID = nil
        }
    }

    public var areSubtitlesEnabled: Bool {
        activeSubtitleTrack >= 0
    }

    public func updateSubtitle(at time: TimeInterval, force: Bool = false) {
        guard activeSubtitleTrack >= 0, let stream = subtitleStream else {
            if !currentSubtitleText.isEmpty {
                currentSubtitleText = ""
                currentSubtitleCueID = nil
            }
            return
        }

        if !force, abs(time - lastSubtitleSyncTime) < Self.subtitleSyncInterval {
            return
        }
        lastSubtitleSyncTime = time

        subtitleUpdateTask?.cancel()
        subtitleUpdateTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            if let cue = await stream.cue(at: time) {
                if !Task.isCancelled {
                    currentSubtitleCueID = cue.id
                    currentSubtitleText = cue.text
                }
            } else if !Task.isCancelled {
                currentSubtitleText = ""
                currentSubtitleCueID = nil
            }
        }
    }

    public func playEpisode(at index: Int) {
        guard index >= 0 && index < episodes.count else { return }
        let ep = episodes[index]
        self.currentEpisodeIndex = index
        self.episodeTitle = ep.title
        
        load(
            url: ep.url,
            title: seriesName,
            movieId: movieId,
            subtitleURL: ep.subtitleURL,
            hdrType: hdrType,
            episodeTitle: ep.title
        )
    }

    public func playNextEpisode() {
        guard let currentIndex = currentEpisodeIndex, currentIndex + 1 < episodes.count else { return }
        let nextIndex = currentIndex + 1
        playEpisode(at: nextIndex)
    }

    public func toggleFullScreen() {
        guard let window = NSApplication.shared.keyWindow else { return }
        window.toggleFullScreen(nil)
    }

    public func retryPlayback() {
        guard let last = lastPlaybackLoad else {
            PlaybackLog.log("retryPlayback skipped — no prior load")
            return
        }
        let isTorrent = last.url.host.map { $0 == "127.0.0.1" || $0 == "localhost" } ?? false
        let resume: Double? = isTorrent ? nil : (currentTime > 20 ? currentTime : last.resumePosition)
        PlaybackLog.log("retryPlayback url=\(PlaybackLog.redactURL(last.url))")
        load(
            url: last.url,
            title: last.title,
            movieId: last.movieId,
            subtitleURL: last.subtitleURL,
            hdrType: last.hdrType,
            audioFormat: last.audioFormat,
            subtitleAppearance: last.subtitleAppearance,
            subtitleFontSize: last.subtitleFontSize,
            episodeTitle: last.episodeTitle,
            episodes: last.episodes,
            currentEpisodeIndex: last.currentEpisodeIndex,
            displayTitle: last.displayTitle,
            resumePosition: resume,
            knownDurationSeconds: duration > 0 ? duration : nil
        )
    }

    public func dismiss() {
        if let window = NSApplication.shared.keyWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        if let prevFrame = previousWindowFrame, let window = NSApplication.shared.keyWindow, !window.styleMask.contains(.fullScreen) {
            window.setFrame(prevFrame, display: true, animate: true)
            previousWindowFrame = nil
        }

        guard isPresented else { return }

        presentationTransitionTask?.cancel()
        isPlaying = false
        player.pause()

        withAnimation(.easeInOut(duration: 0.38)) {
            isPlayerRevealed = false
        }

        presentationTransitionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.38)) {
                isPresented = false
            }
            finalizeDismissal()
        }
    }

    private func finalizeDismissal() {
        stopPlaybackResources()
        isStreamingTorrent = false
        dismissPlaybackWhenPiPCloses = false
        isPlaybackChromeHidden = false
        isPlayerRevealed = false
        isPresented = false
        currentTime = 0
        duration = 0
        bufferedTimeRanges = []
        errorMessage = nil
        episodes = []
        currentEpisodeIndex = nil
        isEpisodesSidebarOpen = false
        isSourcesSidebarOpen = false
        isSubtitlesSidebarOpen = false
        availableSubtitles = []
        selectedSubtitleID = nil
        isLoadingSubtitleCatalog = false
        onSelectSubtitle = nil
        onRefreshSubtitles = nil
        pendingResumePosition = nil
        isBuffering = false
        bufferingDetail = nil
        seriesName = ""
        episodeTitle = nil
        hdrType = nil
        audioFormat = nil
        qualityBadgePillShownForCurrentItem = false
        playbackSources = []
        selectedPlaybackSourceID = nil
        isSwitchingSource = false
        onSelectPlaybackSource = nil
        lastPlaybackLoad = nil
        streamsFromLocalTorrentServer = false
        if let existing = thumbnailService {
            Task { await existing.clearCache() }
        }
        thumbnailService = nil
    }

    public func updatePlaybackSources(_ sources: [PlaybackSourceOption], selectedID: String?) {
        playbackSources = sources
        selectedPlaybackSourceID = selectedID
    }

    private func stopPlaybackResources() {
        setHUDStatusPill(nil)
        stopFastScan()
        removeObservers()
        teardownPiP()
        cancelSubtitleWork()
        player.pause()
        player.replaceCurrentItem(with: nil)
        observedPlayerItem = nil
    }

    private func cancelSubtitleWork() {
        subtitleLoadTask?.cancel()
        subtitleLoadTask = nil
        subtitleUpdateTask?.cancel()
        subtitleUpdateTask = nil
        subtitleStream = nil
        subtitleURL = nil
        activeSubtitleTrack = -1
        currentSubtitleText = ""
        currentSubtitleCueID = nil
        lastSubtitleSyncTime = -1
    }

    private func teardownPiP() {
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        pipController = nil
        pipDelegate = nil
        isPictureInPictureActive = false
        isPictureInPicturePossible = false
    }

    public func setupPiP(with playerLayer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard pipController == nil else { return }
        let delegate = PlayerPiPDelegate(state: self)
        pipDelegate = delegate
        let controller = AVPictureInPictureController(playerLayer: playerLayer)
        controller?.delegate = delegate
        pipController = controller
        isPictureInPicturePossible = controller?.isPictureInPicturePossible ?? false
    }

    public func togglePictureInPicture() {
        guard let controller = pipController else { return }
        if controller.isPictureInPictureActive {
            isPictureInPictureActive = false
            controller.stopPictureInPicture()
        } else {
            dismissPlaybackWhenPiPCloses = false
            isPictureInPictureActive = true
            controller.startPictureInPicture()
        }
    }

    @discardableResult
    public func startPictureInPictureIfPossible() -> Bool {
        guard let controller = pipController else { return false }
        if controller.isPictureInPictureActive { return true }
        guard controller.isPictureInPicturePossible else { return false }
        isPictureInPictureActive = true
        controller.startPictureInPicture()
        return true
    }

    /// Hides full-screen player chrome, keeps AVPlayer running, and enters PiP when supported.
    public func minimizeToPictureInPicture() {
        guard isPresented else { return }
        dismissPlaybackWhenPiPCloses = true
        presentationTransitionTask?.cancel()
        withAnimation(.easeInOut(duration: 0.38)) {
            isPlaybackChromeHidden = true
            isPlayerRevealed = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            for attempt in 0..<6 {
                if startPictureInPictureIfPossible() { return }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    public func restorePlaybackChrome() {
        guard isPresented else { return }
        dismissPlaybackWhenPiPCloses = false
        presentationTransitionTask?.cancel()
        withAnimation(.easeInOut(duration: 0.38)) {
            isPlaybackChromeHidden = false
            isPlayerRevealed = true
        }
    }

    /// PiP closed via X while browsing — stop video, do not reopen the in-app player.
    fileprivate func dismissFromDetachedPiPClose() {
        dismissPlaybackWhenPiPCloses = false
        dismiss()
    }

    public func togglePlayback() {
        if player.timeControlStatus == .playing {
            pause()
        } else {
            if isFastScanning {
                stopFastScan()
            }
            play()
        }
    }

    public func play() {
        if playbackRate <= 0 {
            playbackRate = 1.0
        }
        if streamsFromLocalTorrentServer, shouldRestartTorrentStreamFromBeginning() {
            seek(to: 0)
        }
        player.play()
        player.rate = Float(playbackRate)
        isPlaying = true
    }

    public func thumbnailImage(for seconds: Double, requestID: UInt64) async -> (UInt64, NSImage?) {
        guard let service = thumbnailService else { return (requestID, nil) }
        let result = await service.thumbnail(at: seconds, requestID: requestID)
        guard let cgImage = result.image else { return (result.requestID, nil) }
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return (result.requestID, NSImage(cgImage: cgImage, size: size))
    }

    public func pause() {
        if isFastScanning {
            stopFastScan()
        }
        player.pause()
        playbackRate = 1.0
        player.rate = 0
        isPlaying = false
    }

    public func seek(to time: Double) {
        let clamped = max(0, min(time, duration))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
        lastSubtitleSyncTime = -1
        updateSubtitle(at: clamped, force: true)
    }

    public func seek(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    public func setVolume(_ value: Float) {
        volume = value
        player.volume = value
    }

    public func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    public func setPlaybackRate(_ rate: Double) {
        guard !isFastScanning else { return }
        playbackRate = rate
        player.rate = Float(rate)
        presentPlaybackRateHUDPill()
    }

    public func startFastScan(forward: Bool) {
        guard isPresented else { return }

        if isFastScanning {
            // Allow live direction switching while Command is still held.
            if fastScanIsForward == forward { return }
            fastScanBackwardTask?.cancel()
        } else {
            wasPlayingBeforeFastScan = player.timeControlStatus == .playing
        }

        isFastScanning = true
        fastScanIsForward = forward
        cancelHUDPillDismissTask()
        setHUDStatusPill(.fastScan(
            icon: forward ? "forward.fill" : "backward.fill",
            multiplier: 2
        ))
        fastScanBackwardTask?.cancel()
        player.pause()
        isPlaying = false
        startBackwardSeekRepeat(forward: forward)
    }

    public func stopFastScan() {
        guard isFastScanning else { return }
        cancelHUDPillDismissTask()
        isFastScanning = false
        setHUDStatusPill(nil)
        fastScanIsForward = false
        fastScanBackwardTask?.cancel()
        fastScanBackwardTask = nil
        if wasPlayingBeforeFastScan {
            play()
        }
        wasPlayingBeforeFastScan = false
    }

    private func startBackwardSeekRepeat(forward: Bool) {
        fastScanBackwardTask?.cancel()
        fastScanBackwardTask = Task {
            var ticks = 0
            while !Task.isCancelled {
                ticks += 1
                let multiplier = ticks >= 7 ? 4 : 2
                await MainActor.run {
                    let icon = forward ? "forward.fill" : "backward.fill"
                    withAnimation(.playerHUDStatusPill) {
                        self.hudStatusPill = .fastScan(icon: icon, multiplier: multiplier)
                    }
                    let delta = Double(multiplier * 6) * (forward ? 1 : -1)
                    self.seek(by: delta)
                }
                try? await Task.sleep(for: .milliseconds(220))
            }
        }
    }

    public func cyclePlaybackRate() {
        let rates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
        if let idx = rates.firstIndex(of: playbackRate) {
            let next = rates[(idx + 1) % rates.count]
            setPlaybackRate(next)
        }
    }

    private func setupObservers() {
        removeObservers()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: Self.timeObserverInterval, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            self.currentTime = seconds
            if let item = self.player.currentItem {
                self.bufferedTimeRanges = item.loadedTimeRanges.compactMap { value in
                    let range = value.timeRangeValue
                    let start = CMTimeGetSeconds(range.start)
                    let end = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
                    guard start.isFinite, end.isFinite, end > start else { return nil }
                    return start...end
                }
            } else {
                self.bufferedTimeRanges = []
            }
            self.updateSubtitle(at: seconds)
            self.tryApplyPendingResume()

            guard self.movieId != 0, self.duration > 0 else { return }
            let now = Date()
            let positionDelta = abs(seconds - self.lastReportedPosition)
            let elapsed = now.timeIntervalSince(self.lastPositionReportTime)
            guard elapsed >= Self.positionReportInterval || positionDelta >= Self.positionReportMinimumDelta else {
                return
            }
            self.lastPositionReportTime = now
            self.lastReportedPosition = seconds
            self.onPositionUpdate?(self.movieId, seconds, self.duration)
        }

        guard let currentItem = player.currentItem else { return }
        observedPlayerItem = currentItem

        let asset = currentItem.asset
        Task { [weak self] in
            guard let durationValue = try? await asset.load(.duration),
                  durationValue.isNumeric else { return }
            let seconds = durationValue.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            await MainActor.run {
                guard let self, currentItem === self.observedPlayerItem else { return }
                self.duration = seconds
            }
        }

        itemStatusObserver = currentItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, item === self.observedPlayerItem else { return }
                switch item.status {
                case .failed:
                    let message = Self.playbackFailureMessage(from: item.error)
                    PlaybackLog.log("AVPlayerItem failed: \(message)")
                    self.errorMessage = message
                    self.isBuffering = false
                case .readyToPlay:
                    let readyDuration = item.asset.duration.seconds
                    if readyDuration.isFinite, readyDuration > 0 {
                        self.duration = readyDuration
                    }
                    PlaybackLog.log("AVPlayerItem readyToPlay duration=\(self.duration)s")
                    self.errorMessage = nil
                    self.bufferingDetail = nil
                    self.tryApplyPendingResume()
                    self.updateBufferingState(for: item)
                    self.presentQualityBadgesHUDPillIfNeeded()
                case .unknown:
                    PlaybackLog.log("AVPlayerItem status=unknown (buffering)")
                    self.updateBufferingState(for: item)
                @unknown default:
                    break
                }
            }
        }

        playbackBufferObserver = currentItem.observe(\.isPlaybackBufferEmpty, options: [.new, .initial]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, item === self.observedPlayerItem else { return }
                self.updateBufferingState(for: item)
            }
        }

        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: currentItem,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.playNextEpisode()
            }
        }

        presentationSizeObserver = currentItem.observe(\.presentationSize, options: [.new, .initial]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, item === self.observedPlayerItem else { return }
                let size = item.presentationSize
                guard size.width > 1, size.height > 1 else { return }
                self.resizeWindowToMatch(aspectRatio: size)
            }
        }

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let playing = status == .playing
                    if self.isPlaying != playing {
                        PlaybackLog.log("timeControlStatus=\(status) isPlaying=\(playing)")
                    }
                    self.isPlaying = playing
                    if status == .waitingToPlayAtSpecifiedRate,
                       let reason = self.player.reasonForWaitingToPlay {
                        PlaybackLog.log("waitingToPlay reason=\(reason.rawValue)")
                    }
                    self.updateBufferingState()
                }
            }
            .store(in: &cancellables)
    }

    private func tryApplyPendingResume() {
        guard let resume = pendingResumePosition, resume > 20 else { return }
        guard observedPlayerItem?.status == .readyToPlay else { return }
        if streamsFromLocalTorrentServer, !isPlaybackTimeBuffered(resume) { return }
        pendingResumePosition = nil
        PlaybackLog.log("resume at \(Int(resume))s")
        seek(to: resume)
    }

    private func isPlaybackTimeBuffered(_ seconds: Double) -> Bool {
        if seconds < 45 { return true }
        guard let item = observedPlayerItem else { return false }
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = CMTimeGetSeconds(range.start)
            let end = start + CMTimeGetSeconds(range.duration)
            guard start.isFinite, end.isFinite, end > start else { continue }
            if seconds >= start - 1, seconds < end { return true }
        }
        return false
    }

    private func shouldRestartTorrentStreamFromBeginning() -> Bool {
        let t = currentTime
        if !t.isFinite || t < 1 { return true }
        if duration > 0, t >= max(0, duration - 3) { return true }
        if pendingResumePosition != nil, !isPlaybackTimeBuffered(t) { return true }
        if observedPlayerItem?.status == .failed { return true }
        let size = observedPlayerItem?.presentationSize ?? .zero
        return size.width < 2 && size.height < 2
    }

    private func updateBufferingState(for item: AVPlayerItem? = nil) {
        let item = item ?? observedPlayerItem

        if !isPresented || errorMessage != nil {
            isBuffering = false
            return
        }

        if isSwitchingSource {
            isBuffering = true
            return
        }

        if player.timeControlStatus == .paused {
            isBuffering = false
            return
        }

        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let itemStalled = item.map { $0.isPlaybackBufferEmpty || $0.status == .unknown } ?? true
        isBuffering = waiting || itemStalled
    }

    private func resizeWindowToMatch(aspectRatio: CGSize) {
        guard !hasResizedForCurrentVideo else { return }
        guard aspectRatio.width > 0, aspectRatio.height > 0 else { return }

        guard let window = NSApplication.shared.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.isKeyWindow }),
              !window.styleMask.contains(.fullScreen) else { return }

        hasResizedForCurrentVideo = true

        let currentFrame = window.frame
        if previousWindowFrame == nil {
            previousWindowFrame = currentFrame
        }

        let ratio = aspectRatio.width / aspectRatio.height
        let newHeight = currentFrame.width / ratio

        guard abs(currentFrame.height - newHeight) > 10 else { return }

        var newFrame = currentFrame
        newFrame.size.height = newHeight
        newFrame.origin.y = currentFrame.origin.y + (currentFrame.height - newHeight) / 2
        window.setFrame(newFrame, display: true, animate: true)
    }

    private func removeObservers() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        playbackBufferObserver?.invalidate()
        playbackBufferObserver = nil
        presentationSizeObserver?.invalidate()
        presentationSizeObserver = nil
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
            self.playbackEndObserver = nil
        }
        cancellables.removeAll()
    }
}

public struct AVPlayerLayerView: NSViewRepresentable {
    private let player: AVPlayer
    private let state: PlayerState

    public init(player: AVPlayer, state: PlayerState) {
        self.player = player
        self.state = state
    }

    public func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = state.videoGravity
        DispatchQueue.main.async {
            state.setupPiP(with: view.playerLayer)
        }
        return view
    }

    public func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        nsView.playerLayer.player = player
        nsView.playerLayer.videoGravity = state.videoGravity
        if state.isPresented {
            state.setupPiP(with: nsView.playerLayer)
        }
    }
}

public final class PlayerContainerView: NSView {
    public var playerLayer: AVPlayerLayer {
        guard let playerLayer = layer as? AVPlayerLayer else {
            fatalError("PlayerContainerView requires AVPlayerLayer backing layer")
        }
        return playerLayer
    }

    public override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.wantsExtendedDynamicRangeContent = true
        return layer
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    public override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

public struct PlayerView<
    SourcesSidebar: View,
    SubtitlesSidebar: View,
    StreamStatsAccessory: View
>: View {
    private let surfaceCornerRadius: CGFloat = 14
    @Bindable private var state: PlayerState
    @ViewBuilder private var sourcesSidebar: () -> SourcesSidebar
    @ViewBuilder private var subtitlesSidebar: () -> SubtitlesSidebar
    @ViewBuilder private var streamStatsAccessory: () -> StreamStatsAccessory
    @State private var controlFadeTask: Task<Void, Never>?
    @State private var isHoveringHUD: Bool = false
    @State private var skipBackTrigger: Int = 0
    @State private var skipForwardTrigger: Int = 0
    @State private var isCommandHeld = false
    @State private var isShiftHeld = false
    @State private var nerdStatsPresented = false
    @State private var nerdStatsSnapshot = DiagnosticsPanelSnapshot.empty
    @State private var nerdStatsRefreshTask: Task<Void, Never>?

    public init(
        state: PlayerState,
        @ViewBuilder sourcesSidebar: @escaping () -> SourcesSidebar = { EmptyView() },
        @ViewBuilder subtitlesSidebar: @escaping () -> SubtitlesSidebar = { EmptyView() },
        @ViewBuilder streamStatsAccessory: @escaping () -> StreamStatsAccessory = { EmptyView() }
    ) {
        self.state = state
        self.sourcesSidebar = sourcesSidebar
        self.subtitlesSidebar = subtitlesSidebar
        self.streamStatsAccessory = streamStatsAccessory
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Native AVPlayer rendering layer
            AVPlayerLayerView(player: state.player, state: state)
                .ignoresSafeArea()

            // Elegant native vignetting overlay when controls are showing to elevate legibility
            if state.showsControls {
                ZStack {
                    Color.black.opacity(0.18)
                    
                    LinearGradient(
                        colors: [Color.black.opacity(0.45), Color.clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                    .frame(height: 160)
                    .frame(maxHeight: .infinity, alignment: .top)
                    
                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(0.55)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .frame(height: 180)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .ignoresSafeArea()
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            subtitleOverlay

            if state.isBuffering || state.isSwitchingSource {
                bufferingOverlay
                    .transition(.opacity)
            }

            if let pill = state.hudStatusPill {
                PlayerHUDStatusPill(model: pill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 72)
                    .transition(.playerHUDStatusPillWarp)
            }

            // Beautiful, floating glassmorphic IINA top bar
            topHUD
                .opacity(state.showsControls ? 1 : 0)
                .animation(state.showsControls ? Self.hudShowAnimation : Self.hudHideAnimation, value: state.showsControls)

            // Center play/pause & seek overlay (hidden while buffering)
            if !state.isBuffering && !state.isSwitchingSource {
                centerControls
            }

            // Stunning, floating glassmorphic IINA control pod
            bottomHUD
                .opacity(state.showsControls ? 1 : 0)
                .animation(state.showsControls ? Self.hudShowAnimation : Self.hudHideAnimation, value: state.showsControls)

            if let errorMsg = state.errorMessage {
                playbackErrorOverlay(message: errorMsg)
                    .transition(.opacity)
                    .zIndex(8)
            }
        }
        .overlay {
            PlayerKeyboardCaptureView(
                state: state,
                onActivity: resetControlFade,
                onSkipBack: { skipBackTrigger += 1 },
                onSkipForward: { skipForwardTrigger += 1 },
                onCommandHeld: { isCommandHeld = $0 },
                onShiftHeld: { isShiftHeld = $0 }
            )
        }
        .overlay {
            MouseTrackingView(onMove: resetControlFade)
        }
        .ignoresSafeArea()
        .task {
            resetControlFade()
            NotificationCenter.default.post(name: .playerReclaimKeyboardFocus, object: nil)
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: surfaceCornerRadius,
                style: .continuous
            )
        )
        .compositingGroup()
    }

    private var bufferingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            if let detail = state.bufferingDetail?.trimmingCharacters(in: .whitespacesAndNewlines),
               !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 520)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func playbackErrorOverlay(message: String) -> some View {
        ZStack {
            // No scrim - transparent overlay

            // Error card - matches app's glass design language
            VStack(spacing: 16) {
                // Icon with app accent color
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 44))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color(red: 0.98, green: 0.36, blue: 0.18))

                // Descriptive error message
                VStack(spacing: 6) {
                    Text("Playback failed")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    Text(formatErrorMessage(message))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                }

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Button(action: { state.retryPlayback() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Retry")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color(red: 0.98, green: 0.36, blue: 0.18))
                            .clipShape(Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.defaultAction)

                        Button(action: { state.dismiss() }) {
                            Text("Close")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.primary.opacity(0.12))
                                .clipShape(Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                    }

                    Button(action: { copyPlaybackDiagnostics() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                            Text("Copy Logs")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
            .adaptiveGlass(cornerRadius: 24)
            .padding(.horizontal, 28)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }



    private func formatErrorMessage(_ rawMessage: String) -> String {
        let lower = rawMessage.lowercased()
        
        if lower.contains("resource unavailable") || lower.contains("404") {
            return "The video file could not be found. This usually means the source is no longer available or the URL is invalid."
        } else if lower.contains("timeout") || lower.contains("timed out") {
            return "The connection took too long to respond. Check your internet connection and try again."
        } else if lower.contains("503") || lower.contains("service unavailable") || lower.contains("buffering from the torrent") {
            return "That part of the file is not downloaded yet. Keep the torrent running and tap play again later — waiting on this error screen alone will not start playback."
        } else if lower.contains("cannot open") {
            return "The stream could not be opened yet (buffer or index data missing). Keep downloading, then tap play again — especially for MKV, the end of the file matters."
        } else if lower.contains("incomplete or corrupt")
            || lower.contains("buffer was incomplete")
            || lower.contains("not buffered that part") {
            return rawMessage
        } else if lower.contains("network") || lower.contains("connection refused") {
            return "Network connection failed. Check your internet connection and make sure the server is reachable."
        } else if lower.contains("authorization") || lower.contains("forbidden") || lower.contains("403") {
            return "Access denied. You may not have permission to play this content."
        } else if lower.contains("format") || lower.contains("codec") || lower.contains("unsupported") {
            return "This video format is not supported by your player."
        } else if lower.contains("drm") || lower.contains("protected") {
            return "This content is protected and cannot be played."
        } else if lower.contains("certificate") || lower.contains("ssl") || lower.contains("tls") {
            return "Secure connection failed. There may be a certificate issue."
        } else {
            // Return a cleaned up version of the raw message
            let cleaned = rawMessage.replacingOccurrences(of: "_", with: " ")
            return cleaned.isEmpty ? "An unknown error occurred. Check your connection and try again." : cleaned
        }
    }

    private func copyPlaybackDiagnostics() {
        let assetURL = (state.player.currentItem?.asset as? AVURLAsset)?.url.absoluteString ?? "No URL"
        let logText = """
        Playback Error: \(state.errorMessage ?? "Unknown error")
        Formatted: \(formatErrorMessage(state.errorMessage ?? ""))
        URL: \(assetURL)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
    }

    private var subtitleOverlay: some View {
        SubtitleOverlayView(
            text: state.currentSubtitleText,
            cueID: state.currentSubtitleCueID,
            appearance: state.subtitleAppearance,
            fontSize: state.subtitleFontSize,
            isVisible: state.activeSubtitleTrack >= 0
        )
    }

    private var topHUD: some View {
        VStack {
            HStack {
                // Top-Left Group
                HStack(spacing: 12) {
                    // Close Button
                    Button {
                        state.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 30, height: 30)
                            .nativeGlassEffect()
                    }
                    .buttonStyle(.plain)

                    // Utilities Capsule
                    HStack(spacing: 16) {
                        Button {
                            state.togglePictureInPicture()
                        } label: {
                            Image(systemName: state.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(state.isPictureInPictureActive ? 1.0 : 0.85))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.05, dampingFraction: 0.95), value: state.isPictureInPictureActive)

                        Button {
                            state.toggleFullScreen()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .nativeGlassEffect()
                }

                Spacer()

                // Top-Right Group: Stream stats (torrent) + Volume + Episodes
                HStack(spacing: 12) {
                    if state.movieId == 0 {
                        Button {
                            nerdStatsPresented.toggle()
                        } label: {
                            Image(systemName: "gauge.with.dots.needle.67percent")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(nerdStatsPresented ? 1.0 : 0.85))
                                .frame(width: 30, height: 30)
                                .nativeGlassEffect()
                        }
                        .buttonStyle(.plain)
                        .help("Nerd stats")
                        .popover(isPresented: $nerdStatsPresented, arrowEdge: .bottom) {
                            DiagnosticsStatsPopover(snapshot: nerdStatsSnapshot)
                                .onAppear { startNerdStatsRefresh() }
                                .onDisappear { stopNerdStatsRefresh() }
                        }
                        .onChange(of: nerdStatsPresented) { _, presented in
                            if presented {
                                startNerdStatsRefresh()
                            } else {
                                stopNerdStatsRefresh()
                            }
                        }
                    } else {
                        streamStatsAccessory()
                    }

                    HStack(spacing: 12) {
                        CustomSlider(value: Binding(
                            get: { Double(state.volume) },
                            set: { state.setVolume(Float($0)) }
                        ), range: 0...1)
                        .frame(width: 80)

                        Button {
                            state.isMuted.toggle()
                            state.player.isMuted = state.isMuted
                        } label: {
                            Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: Double(state.volume))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)

                        // Episodes Button (TV only)
                        if !state.episodes.isEmpty {
                            Divider()
                                .frame(height: 20)

                            Button {
                                state.isEpisodesSidebarOpen.toggle()
                                if state.isEpisodesSidebarOpen {
                                    state.isSourcesSidebarOpen = false
                                    state.isSubtitlesSidebarOpen = false
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white.opacity(state.isEpisodesSidebarOpen ? 1.0 : 0.85))
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .buttonStyle(.plain)
                            .help("Episodes")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .nativeGlassEffect()
                }
            }
            .padding(.top, 24)
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var centerControls: some View {
        HStack(spacing: 28) {
            SkipSeekButton(
                state: state,
                direction: .back,
                isCommandHeld: isCommandHeld,
                isShiftHeld: isShiftHeld,
                pulseTrigger: $skipBackTrigger,
                onActivity: resetControlFade
            )

            Button {
                state.togglePlayback()
                resetControlFade()
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 72, height: 72)
                    .nativeGlassEffect()
            }
            .buttonStyle(CenterHUDButtonStyle())
            .animation(.spring(response: 0.02, dampingFraction: 0.85), value: state.isPlaying)

            SkipSeekButton(
                state: state,
                direction: .forward,
                isCommandHeld: isCommandHeld,
                isShiftHeld: isShiftHeld,
                pulseTrigger: $skipForwardTrigger,
                onActivity: resetControlFade
            )
        }
        .scaleEffect(state.showsControls ? 1.0 : 0.9)
        .opacity(state.showsControls ? 1.0 : 0.0)
        .animation(.spring(response: 0.08, dampingFraction: 0.92), value: state.showsControls)
    }

    private static var hudShowAnimation: Animation {
        .easeIn(duration: 0.18)
    }

    private static var hudHideAnimation: Animation {
        .easeOut(duration: 0.06)
    }

    private var scrubberTransportControls: some View {
        Button {
            state.togglePlayback()
            resetControlFade()
        } label: {
            Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.02, dampingFraction: 0.85), value: state.isPlaying)
        .help(state.isPlaying ? "Pause" : "Play")
    }

    private var bottomHUD: some View {
        HStack(spacing: 0) {
            // Episodes Sidebar (slides in from left)
            if state.isEpisodesSidebarOpen && !state.episodes.isEmpty {
                episodesSidebar
                    .transition(.move(edge: .leading))
            }
            
            VStack {
                Spacer()

                // TV Series & Episode Metadata overlay (left-aligned)
                HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if let epTitle = state.episodeTitle, !epTitle.isEmpty {
                        Text(epTitle)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.white.opacity(0.70))
                    }
                    
                    Text(state.seriesName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 6)

            HStack(alignment: .center, spacing: 14) {
                // Wide floating scrubber capsule
                HStack(alignment: .center, spacing: 12) {
                    scrubberTransportControls

                    Text(formatTime(state.currentTime))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 56, alignment: .trailing)

                    ScrubberSlider(
                        value: Binding(
                            get: { state.currentTime },
                            set: { state.seek(to: $0) }
                        ),
                        range: 0...max(state.duration, 0.01),
                        bufferedRanges: state.bufferedTimeRanges,
                        formatTime: formatTime,
                        thumbnailProvider: { time, requestID in
                            await state.thumbnailImage(for: time, requestID: requestID)
                        }
                    )
                    .frame(maxWidth: .infinity)

                    Text(formatRemainingTime())
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 56, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .nativeGlassEffect()
                .frame(maxWidth: .infinity)

                // Quality, subtitles, rate, aspect
                HStack(spacing: 18) {
                    if !state.playbackSources.isEmpty {
                        sourcesSidebarButton
                    }

                    Menu {
                        Button("0.5x") { state.setPlaybackRate(0.5) }
                        Button("1.0x") { state.setPlaybackRate(1.0) }
                        Button("1.25x") { state.setPlaybackRate(1.25) }
                        Button("1.5x") { state.setPlaybackRate(1.5) }
                        Button("2.0x") { state.setPlaybackRate(2.0) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "timer")
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(state.playbackRate, specifier: "%g")x")
                                .font(.system(size: 10, weight: .bold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    subtitlesSidebarButton

                    // Video Aspect / Zoom Gravity Button
                    Button {
                        state.cycleVideoGravity()
                    } label: {
                        Image(systemName: "aspectratio")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help(state.videoGravityHUDTitle)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .nativeGlassEffect()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .onHover { hovering in
                isHoveringHUD = hovering
            }
            }
            .frame(maxWidth: .infinity)

            if state.isSourcesSidebarOpen && !state.playbackSources.isEmpty {
                sourcesSidebar()
                    .transition(.move(edge: .trailing))
            }

            if state.isSubtitlesSidebarOpen {
                subtitlesSidebar()
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: state.isSourcesSidebarOpen)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: state.isSubtitlesSidebarOpen)
    }

    private var subtitlesSidebarButton: some View {
        Button {
            resetControlFade()
            state.isSubtitlesSidebarOpen.toggle()
            if state.isSubtitlesSidebarOpen {
                state.isSourcesSidebarOpen = false
                state.isEpisodesSidebarOpen = false
            }
        } label: {
            Image(systemName: state.isSubtitlesSidebarOpen || state.areSubtitlesEnabled ? "captions.bubble.fill" : "captions.bubble")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(state.isSubtitlesSidebarOpen || state.areSubtitlesEnabled ? 1.0 : 0.85))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help("Subtitles")
        .disabled(state.onSelectSubtitle == nil && state.onRefreshSubtitles == nil)
    }

    private var sourcesSidebarButton: some View {
        Button {
            resetControlFade()
            state.isSourcesSidebarOpen.toggle()
            if state.isSourcesSidebarOpen {
                state.isEpisodesSidebarOpen = false
                state.isSubtitlesSidebarOpen = false
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(state.isSourcesSidebarOpen || state.isSwitchingSource ? 1.0 : 0.9))
                    .symbolEffect(.pulse, isActive: state.isSwitchingSource)
                if state.isSwitchingSource {
                    ProgressView()
                        .controlSize(.mini)
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Versions & quality")
        .disabled(state.isSwitchingSource || state.onSelectPlaybackSource == nil)
    }

    private var episodesSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Episodes")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.top, 16)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(state.episodes.enumerated()), id: \.element.id) { index, episode in
                        Button {
                            state.playEpisode(at: index)
                            state.isEpisodesSidebarOpen = false
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("S\(episode.seasonNumber)E\(episode.episodeNumber)")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.7))
                                    
                                    Text(episode.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                }
                                
                                Spacer()
                                
                                if index == state.currentEpisodeIndex {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(index == state.currentEpisodeIndex ? Color.white.opacity(0.1) : Color.clear)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: .infinity)
            
            Spacer()
        }
        .frame(width: 260)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(12)
    }

    private func formatRemainingTime() -> String {
        let remaining = max(0, state.duration - state.currentTime)
        return "-\(formatTime(remaining))"
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private func resetControlFade() {
        NotificationCenter.default.post(name: .playerReclaimKeyboardFocus, object: nil)
        state.showsControls = true
        controlFadeTask?.cancel()
        controlFadeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled && !isHoveringHUD && state.isPlaying {
                await MainActor.run {
                    state.showsControls = false
                }
            }
        }
    }

    private func showNerdStats() async {
        guard let item = state.player.currentItem,
              let asset = item.asset as? AVURLAsset else { return }

        let streamURL = asset.url
        var quality = "Adaptive HLS"
        var bitrate = "Adaptive"
        var codec = "Adaptive"
        var observedBitrate = "N/A"
        var indicatedBitrate = "N/A"
        var switchBitrate = "N/A"

        let tracks = try? await item.asset.loadTracks(withMediaType: .video)
        if let track = tracks?.first {
            let size = try? await track.load(.naturalSize)
            let transform = try? await track.load(.preferredTransform)
            if let size, let transform {
                let rendered = size.applying(transform)
                let w = Int(abs(rendered.width))
                let h = Int(abs(rendered.height))
                if w > 0 && h > 0 {
                    quality = "\(w)x\(h)"
                }
            }

            let rate = track.estimatedDataRate
            if rate > 0 {
                bitrate = String(format: "%.2f Mbps", rate / 1_000_000)
            }

            if let desc = track.formatDescriptions.first {
                let mediaSubType = CMFormatDescriptionGetMediaSubType(desc as! CMFormatDescription)
                codec = fourCCString(mediaSubType)
            }
        }

        let ext = streamURL.pathExtension.uppercased()
        let format = ext == "M3U8" ? "HLS (M3U8)" : (ext.isEmpty ? "Unknown" : ext)
        if ext == "M3U8" {
            let accessEvent = item.accessLog()?.events.last
            if let accessEvent {
                if accessEvent.observedBitrate > 0 {
                    observedBitrate = formatMbps(accessEvent.observedBitrate)
                }
                if accessEvent.indicatedBitrate > 0 {
                    indicatedBitrate = formatMbps(accessEvent.indicatedBitrate)
                    bitrate = indicatedBitrate
                }
                if accessEvent.switchBitrate > 0 {
                    switchBitrate = formatMbps(accessEvent.switchBitrate)
                }
            }

            if let hlsProbe = await probeHlsStats(from: streamURL) {
                if let variant = bestMatchingVariant(
                    variants: hlsProbe.variants,
                    targetBitrate: accessEvent?.indicatedBitrate
                ) {
                    quality = variant.quality ?? quality
                    codec = variant.codec ?? codec
                    bitrate = formatMbps(Double(variant.bandwidth))
                } else {
                    if let qualityText = hlsProbe.quality {
                        quality = qualityText
                    }
                    if let bitrateText = hlsProbe.bitrate {
                        bitrate = bitrateText
                    }
                    if let codecText = hlsProbe.codec {
                        codec = codecText
                    }
                }
            }
        }
        let title = state.seriesName.isEmpty ? state.title : state.seriesName
        let capturedAt = Date()
        nerdStatsSnapshot = DiagnosticsPanelSnapshot(
            title: "Nerd Stats",
            subtitle: "Updated \(capturedAt.formatted(date: .omitted, time: .standard))",
            capturedAt: capturedAt,
            sections: [
                DiagnosticsPanelSnapshot.Section(
                    title: "Playback",
                    rows: [
                        .init(label: "Title", value: title),
                        .init(label: "Format", value: format),
                        .init(label: "Quality", value: quality),
                        .init(label: "Bitrate", value: bitrate),
                        .init(label: "Codec", value: codec),
                        .init(label: "Observed", value: observedBitrate),
                        .init(label: "Indicated", value: indicatedBitrate),
                        .init(label: "Switch", value: switchBitrate),
                    ]
                ),
                DiagnosticsPanelSnapshot.Section(
                    title: "Source",
                    rows: [
                        .init(label: "URL", value: streamURL.absoluteString),
                    ]
                ),
            ],
            emptyTitle: "No playback data",
            emptyDescription: "Stats appear while a trailer or clip is playing.",
            emptySystemImage: "play.rectangle"
        )
    }

    private func startNerdStatsRefresh() {
        nerdStatsRefreshTask?.cancel()
        nerdStatsRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                await showNerdStats()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func stopNerdStatsRefresh() {
        nerdStatsRefreshTask?.cancel()
        nerdStatsRefreshTask = nil
    }

    private func fourCCString(_ code: FourCharCode) -> String {
        let n = Int(code)
        let c1 = Character(UnicodeScalar((n >> 24) & 255)!)
        let c2 = Character(UnicodeScalar((n >> 16) & 255)!)
        let c3 = Character(UnicodeScalar((n >> 8) & 255)!)
        let c4 = Character(UnicodeScalar(n & 255)!)
        return String([c1, c2, c3, c4])
    }

    private func probeHlsStats(from manifestURL: URL) async -> HLSStatsProbe? {
        let responseText = await fetchText(from: manifestURL)
        guard let responseText else { return nil }
        let lines = responseText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !lines.isEmpty else { return nil }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) {
            return parseMasterHls(lines: lines)
        }
        return parseMediaHls(lines: lines)
    }

    private func parseMasterHls(lines: [String]) -> HLSStatsProbe {
        var bestPixels = 0
        var bestBitrate = 0
        var bestCodec: String?
        var variants: [HLSVariant] = []

        for line in lines where line.hasPrefix("#EXT-X-STREAM-INF:") {
            let value = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
            let attrs = parseM3U8Attributes(value)
            var variantPixels = 0
            var variantQuality: String?
            var variantBitrate = 0

            if let resolution = attrs["RESOLUTION"] {
                let parts = resolution.uppercased().split(separator: "X")
                if parts.count == 2,
                   let width = Int(parts[0]),
                   let height = Int(parts[1]) {
                    variantPixels = width * height
                    variantQuality = "\(height)p (\(width)x\(height))"
                    bestPixels = max(bestPixels, variantPixels)
                }
            }

            if let bandwidthString = attrs["BANDWIDTH"], let bandwidth = Int(bandwidthString) {
                bestBitrate = max(bestBitrate, bandwidth)
                variantBitrate = bandwidth
            }
            var normalizedCodec: String?
            if let codecsValue = attrs["CODECS"], !codecsValue.isEmpty {
                normalizedCodec = normalizeCodec(codecsValue)
                bestCodec = normalizedCodec
            }

            if variantBitrate > 0 {
                variants.append(
                    HLSVariant(
                        bandwidth: variantBitrate,
                        quality: variantQuality ?? (variantPixels > 0 ? qualityLabel(pixelCount: variantPixels) : nil),
                        codec: normalizedCodec
                    )
                )
            }
        }

        let quality = bestPixels > 0 ? qualityLabel(pixelCount: bestPixels) : nil
        let bitrate = bestBitrate > 0 ? String(format: "%.2f Mbps", Double(bestBitrate) / 1_000_000) : nil
        return HLSStatsProbe(quality: quality, bitrate: bitrate, codec: bestCodec, variants: variants)
    }

    private func parseMediaHls(lines: [String]) -> HLSStatsProbe {
        var peakBitrate = 0
        for line in lines where line.hasPrefix("#EXT-X-BITRATE:") {
            let raw = line.dropFirst("#EXT-X-BITRATE:".count).trimmingCharacters(in: .whitespaces)
            if let bitrate = Int(raw) {
                peakBitrate = max(peakBitrate, bitrate * 1_000)
            }
        }
        let bitrate = peakBitrate > 0 ? String(format: "%.2f Mbps", Double(peakBitrate) / 1_000_000) : nil
        let variants = peakBitrate > 0 ? [HLSVariant(bandwidth: peakBitrate, quality: nil, codec: nil)] : []
        return HLSStatsProbe(quality: nil, bitrate: bitrate, codec: nil, variants: variants)
    }

    private func parseM3U8Attributes(_ input: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let pattern = #"([A-Z0-9-]+)=("([^"]*)"|[^,]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attributes }
        let nsInput = input as NSString
        let range = NSRange(location: 0, length: nsInput.length)
        regex.enumerateMatches(in: input, range: range) { match, _, _ in
            guard let match,
                  let keyRange = Range(match.range(at: 1), in: input),
                  let valueRange = Range(match.range(at: 2), in: input) else { return }
            var value = String(input[valueRange]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            attributes[String(input[keyRange])] = value
        }
        return attributes
    }

    private func normalizeCodec(_ codecList: String) -> String {
        let normalized = codecList
            .replacingOccurrences(of: "\"", with: "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return normalized.isEmpty ? "Adaptive" : normalized
    }

    private func qualityLabel(pixelCount: Int) -> String {
        let tiers = [
            (3840 * 2160, "2160p (4K)"),
            (2560 * 1440, "1440p"),
            (1920 * 1080, "1080p"),
            (1280 * 720, "720p"),
            (854 * 480, "480p")
        ]
        for (threshold, label) in tiers where pixelCount >= threshold {
            return label
        }
        return "SD"
    }

    private func bestMatchingVariant(variants: [HLSVariant], targetBitrate: Double?) -> HLSVariant? {
        guard !variants.isEmpty else { return nil }
        guard let targetBitrate, targetBitrate > 0 else {
            return variants.max(by: { $0.bandwidth < $1.bandwidth })
        }
        return variants.min(by: { lhs, rhs in
            abs(Double(lhs.bandwidth) - targetBitrate) < abs(Double(rhs.bandwidth) - targetBitrate)
        })
    }

    private func formatMbps(_ bitsPerSecond: Double) -> String {
        guard bitsPerSecond > 0 else { return "N/A" }
        return String(format: "%.2f Mbps", bitsPerSecond / 1_000_000)
    }

    private func fetchText(from url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct HLSStatsProbe {
    let quality: String?
    let bitrate: String?
    let codec: String?
    let variants: [HLSVariant]
}

private struct HLSVariant {
    let bandwidth: Int
    let quality: String?
    let codec: String?
}

struct HUDButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.6 : 0.9))
            .frame(width: 32, height: 32)
            .background(.white.opacity(0.08))
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct CenterHUDButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

enum GlassStrength {
    case ultraThin
    case thin
    case regular
    case thick
    case ultraThick
    
    var material: Material {
        switch self {
        case .ultraThin: return .ultraThinMaterial
        case .thin: return .thinMaterial
        case .regular: return .regularMaterial
        case .thick: return .thickMaterial
        case .ultraThick: return .ultraThickMaterial
        }
    }
}

struct NativeVisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var state: NSVisualEffectView.State = .active
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

struct AdaptiveGlass: ViewModifier {
    private let cornerRadius: CGFloat
    private let strength: GlassStrength

    public init(cornerRadius: CGFloat = 18, strength: GlassStrength = .thick) {
        self.cornerRadius = cornerRadius
        self.strength = strength
    }

    public func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(
                    NativeVisualEffectView(material: .hudWindow, blendingMode: .withinWindow, state: .active)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        }
    }
}

extension View {
    func adaptiveGlass(cornerRadius: CGFloat = 18, strength: GlassStrength = .thick) -> some View {
        modifier(AdaptiveGlass(cornerRadius: cornerRadius, strength: strength))
    }
}

struct HUDPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.black)
            .frame(width: 44, height: 44)
            .background(.white)
            .clipShape(Circle())
            .shadow(color: .white.opacity(0.2), radius: 6)
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct VolumeSlider: View {
    let volume: Float
    let onValueChange: (Float) -> Void

    var body: some View {
        Slider(value: Binding(
            get: { Double(volume) },
            set: { onValueChange(Float($0)) }
        ), in: 0...1) {
            Text("Volume")
        }
        .tint(.white)
        .controlSize(.mini)
    }
}

extension Notification.Name {
    static let playerReclaimKeyboardFocus = Notification.Name("playerReclaimKeyboardFocus")
}

/// Invisible first-responder layer — SwiftUI `onKeyPress` does not receive keys when AVPlayer uses an `NSView` layer.
struct PlayerKeyboardCaptureView: NSViewRepresentable {
    var state: PlayerState
    var onActivity: () -> Void
    var onSkipBack: () -> Void
    var onSkipForward: () -> Void
    var onCommandHeld: (Bool) -> Void
    var onShiftHeld: (Bool) -> Void

    func makeNSView(context: Context) -> PlayerKeyboardNSView {
        let view = PlayerKeyboardNSView()
        view.state = state
        view.onActivity = onActivity
        view.onSkipBack = onSkipBack
        view.onSkipForward = onSkipForward
        view.onCommandHeld = onCommandHeld
        view.onShiftHeld = onShiftHeld
        return view
    }

    func updateNSView(_ nsView: PlayerKeyboardNSView, context: Context) {
        nsView.state = state
        nsView.onActivity = onActivity
        nsView.onSkipBack = onSkipBack
        nsView.onSkipForward = onSkipForward
        nsView.onCommandHeld = onCommandHeld
        nsView.onShiftHeld = onShiftHeld
        if state.isPresented {
            nsView.claimKeyboardFocus()
            onCommandHeld(NSEvent.modifierFlags.contains(.command))
            onShiftHeld(NSEvent.modifierFlags.contains(.shift))
        }
    }

    static func dismantleNSView(_ nsView: PlayerKeyboardNSView, coordinator: ()) {
        nsView.teardown()
    }
}

final class PlayerKeyboardNSView: NSView {
    weak var state: PlayerState?
    var onActivity: (() -> Void)?
    var onSkipBack: (() -> Void)?
    var onSkipForward: (() -> Void)?
    var onCommandHeld: ((Bool) -> Void)?
    var onShiftHeld: ((Bool) -> Void)?
    private var focusObserver: NSObjectProtocol?
    private var isCommandKeyHeld = false
    private var isShiftKeyHeld = false

    override var acceptsFirstResponder: Bool { true }

    func teardown() {
        if let focusObserver {
            NotificationCenter.default.removeObserver(focusObserver)
            self.focusObserver = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if focusObserver == nil {
            focusObserver = NotificationCenter.default.addObserver(
                forName: .playerReclaimKeyboardFocus,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.claimKeyboardFocus()
            }
        }
        claimKeyboardFocus()
    }

    func claimKeyboardFocus() {
        guard state?.isPresented == true else { return }
        window?.makeFirstResponder(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func flagsChanged(with event: NSEvent) {
        let commandDown = event.modifierFlags.contains(.command)
        if commandDown != isCommandKeyHeld {
            isCommandKeyHeld = commandDown
            onCommandHeld?(commandDown)
        }
        let shiftDown = event.modifierFlags.contains(.shift)
        if shiftDown != isShiftKeyHeld {
            isShiftKeyHeld = shiftDown
            onShiftHeld?(shiftDown)
        }
        if !commandDown {
            state?.stopFastScan()
        }
        super.flagsChanged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let state else {
            super.keyDown(with: event)
            return
        }

        if event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option) {
            super.keyDown(with: event)
            return
        }

        if handleKeyDown(event, state: state) {
            onActivity?()
            return
        }

        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 123 || event.keyCode == 124 {
            if event.modifierFlags.contains(.command) || state?.isFastScanning == true {
                state?.stopFastScan()
            }
        }
        super.keyUp(with: event)
    }

    private func handleKeyDown(_ event: NSEvent, state: PlayerState) -> Bool {
        let isCommand = event.modifierFlags.contains(.command)
        let isShift = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 49: // space
            guard !isCommand, !isShift else { return false }
            state.togglePlayback()
            return true
        case 123: // left
            if isCommand {
                state.startFastScan(forward: false)
                onSkipBack?()
                return true
            }
            if isShift {
                state.seek(by: -5)
                onSkipBack?()
                return true
            }
            state.seek(by: -15)
            onSkipBack?()
            return true
        case 124: // right
            if isCommand {
                state.startFastScan(forward: true)
                onSkipForward?()
                return true
            }
            if isShift {
                state.seek(by: 5)
                onSkipForward?()
                return true
            }
            state.seek(by: 15)
            onSkipForward?()
            return true
        case 126: // up
            guard !isCommand, !isShift else { return false }
            state.setVolume(min(1.0, state.volume + 0.1))
            return true
        case 125: // down
            guard !isCommand, !isShift else { return false }
            state.setVolume(max(0.0, state.volume - 0.1))
            return true
        case 53: // escape
            state.dismiss()
            return true
        default:
            break
        }

        guard !isCommand, !isShift else { return false }

        guard let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else {
            return false
        }

        switch key {
        case "m":
            state.toggleMute()
            return true
        case "f":
            state.toggleFullScreen()
            return true
        case "s", "c":
            state.toggleSubtitle()
            return true
        case "p":
            state.togglePictureInPicture()
            return true
        case "a":
            state.cycleVideoGravity()
            return true
        default:
            return false
        }
    }
}

struct SkipButtonPulseModifier: ViewModifier {
    let trigger: Int
    @State private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: trigger) { _, _ in
                scale = 1.14
                withAnimation(.spring(response: 0.1, dampingFraction: 0.52)) {
                    scale = 1.0
                }
            }
    }
}

struct MouseTrackingView: NSViewRepresentable {
    let onMove: () -> Void

    func makeNSView(context: Context) -> MouseTrackingNSView {
        let view = MouseTrackingNSView()
        view.onMove = onMove
        let tracker = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: view,
            userInfo: nil
        )
        view.addTrackingArea(tracker)
        return view
    }

    func updateNSView(_ nsView: MouseTrackingNSView, context: Context) {
        nsView.onMove = onMove
    }
}

class MouseTrackingNSView: NSView {
    var onMove: (() -> Void)?

    override func mouseMoved(with event: NSEvent) {
        onMove?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

// Picture in Picture Delegate
public final class PlayerPiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
    private let state: PlayerState

    public init(state: PlayerState) {
        self.state = state
    }

    public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("[DEBUG] PiP will start")
        let activeState = self.state
        Task { @MainActor in
            activeState.isPictureInPictureActive = true
        }
    }

    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("[DEBUG] PiP did start")
    }

    public func pictureInPictureControllerFailedToStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController, error: Error) {
        print("[ERROR] PiP failed to start: \(error.localizedDescription)")
        let activeState = self.state
        Task { @MainActor in
            activeState.isPictureInPictureActive = false
        }
    }

    public func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("[DEBUG] PiP will stop")
    }

    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("[DEBUG] PiP did stop")
        let activeState = self.state
        Task { @MainActor in
            activeState.isPictureInPictureActive = false
            guard activeState.isPlaybackChromeHidden, activeState.isPresented else { return }
            if activeState.dismissPlaybackWhenPiPCloses {
                activeState.dismissFromDetachedPiPClose()
            }
        }
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        let completion = PiPRestoreCompletion(completionHandler)
        let activeState = self.state
        Task { @MainActor in
            activeState.dismissPlaybackWhenPiPCloses = false
            if activeState.isPresented {
                activeState.restorePlaybackChrome()
            }
            completion.finish(true)
        }
    }
}

private final class PiPRestoreCompletion: @unchecked Sendable {
    private let handler: (Bool) -> Void

    init(_ handler: @escaping (Bool) -> Void) {
        self.handler = handler
    }

    func finish(_ success: Bool) {
        handler(success)
    }
}

// Custom Slider for Volume & Scrubber Progress
struct CustomSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var onHoverTime: ((Double?, CGFloat?) -> Void)? = nil
    
    @State private var isHovering = false
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let percentage = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            
            ZStack(alignment: .leading) {
                // Background Track
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(height: 6)
                
                // Active Filled Track
                Capsule()
                    .fill(.white)
                    .frame(width: max(0, min(width * percentage, width)), height: 6)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if !hovering {
                    onHoverTime?(nil, nil)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let locationX = location.x
                    let relativeX = max(0, min(locationX, width))
                    let hoverVal = range.lowerBound + Double(relativeX / width) * (range.upperBound - range.lowerBound)
                    onHoverTime?(hoverVal, locationX)
                case .ended:
                    onHoverTime?(nil, nil)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let locationX = gesture.location.x
                        let relativeX = max(0, min(locationX, width))
                        let newValue = range.lowerBound + Double(relativeX / width) * (range.upperBound - range.lowerBound)
                        value = newValue
                    }
            )
        }
        .frame(height: 12)
    }
}

// Native glass effect modifier
public struct NativeGlassEffectModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect()
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12), lineWidth: 1))
        }
    }
}

public extension View {
    @ViewBuilder
    func nativeGlassEffect() -> some View {
        modifier(NativeGlassEffectModifier())
    }
}

// Native macOS AirPlay Route Picker
struct AirPlayView: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let routePicker = AVRoutePickerView()
        routePicker.isRoutePickerButtonBordered = false
        return routePicker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

// MARK: - Apple-Style Button Styles

struct AppleBlueButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        Color.accentColor.opacity(0.3),
                        lineWidth: 0.5
                    )
            )
            .opacity(isEnabled ? 1 : 0.6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct AppleSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        Color.secondary.opacity(0.2),
                        lineWidth: 0.5
                    )
            )
            .opacity(isEnabled ? 1 : 0.6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}



