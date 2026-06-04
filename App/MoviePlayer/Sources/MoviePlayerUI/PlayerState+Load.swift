@preconcurrency import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


@MainActor
extension PlayerState {
    /// Opens the player immediately and shows buffering until `load(url:)` is called.
    public func beginBufferingPlayback(
        title: String,
        movieId: Int,
        subtitleAppearance: SubtitleAppearance = .modern,
        subtitleFontSize: CGFloat = 20,
        episodeTitle: String? = nil,
        displayTitle: String? = nil,
        posterURL: URL? = nil
    ) {
        errorMessage = nil
        isBuffering = true
        bufferingDetail = "Preparing stream…"
        self.title = title
        self.movieId = movieId
        if let posterURL { self.posterURL = posterURL }
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
        hasResizedForCurrentVideo = false
        lastAutosizedVideoSize = nil
        capturePrePlayerWindowFrame()
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

    public func updatePlaybackQualityWarning(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        playbackQualityWarning = trimmed.isEmpty ? nil : trimmed
    }

    public func load(
        url: URL,
        title: String,
        movieId: Int = 0,
        subtitleURL: URL? = nil,
        hdrType: PlayerHDRType? = nil,
        audioFormat: PlayerAudioFormat? = nil,
        subtitleAppearance: SubtitleAppearance = .modern,
        subtitleFontSize: CGFloat = 20,
        episodeTitle: String? = nil,
        episodes: [PlayerEpisode] = [],
        currentEpisodeIndex: Int? = nil,
        displayTitle: String? = nil,
        resumePosition: Double? = nil,
        knownDurationSeconds: Double? = nil,
        posterURL: URL? = nil,
        resourceLoaderDelegate: AVAssetResourceLoaderDelegate? = nil,
        resourceLoaderQueue: DispatchQueue? = nil
    ) {
        // #region agent log
        DebugAgentLog.write(
            hypothesisId: "H4",
            location: "CorePlayer.swift:load",
            message: "player load",
            data: [
                "ext": url.pathExtension.lowercased(),
                "movieId": String(movieId),
                "resumePosition": resumePosition.map { String($0) } ?? "nil",
                "chromeHidden": String(isPlaybackChromeHidden),
            ]
        )
        // #endregion
        stopPlaybackResources()

        streamsFromLocalTorrentServer =
            Self.isTorrentResourceLoaderURL(url)
            || url.host.map { $0 == "127.0.0.1" || $0 == "localhost" } == true
        isHLSTorrentPlayback = url.pathExtension.lowercased() == "m3u8"
            || url.absoluteString.lowercased().contains(".m3u8")
        if streamsFromLocalTorrentServer {
            isStreamingTorrent = true
        }

        self.title = title
        self.movieId = movieId
        if let posterURL { self.posterURL = posterURL }
        self.subtitleURL = subtitleURL
        self.hdrType = hdrType
        self.audioFormat = audioFormat
        qualityBadgesLockedFromPrepare = hdrType != nil || audioFormat != nil
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
        lastAutosizedVideoSize = nil

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
            currentTime = resumePosition
        } else {
            pendingResumePosition = nil
            currentTime = 0
        }
        peakPlaybackTime = 0

        if let knownDurationSeconds, knownDurationSeconds.isFinite, knownDurationSeconds > 0 {
            duration = knownDurationSeconds
            trustedDurationSeconds = knownDurationSeconds
        } else {
            duration = 0
            trustedDurationSeconds = nil
        }
        cachedStreamBufferRanges = []

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
        PlaybackLog.log("[MKVHLS] PlayerState.load scheme=\(url.scheme ?? "none") host=\(url.host ?? "none") port=\(url.port ?? -1) ext=\(url.pathExtension.lowercased()) isFile=\(url.isFileURL) title=\"\(title)\"")

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
            resumePosition: resumePosition,
            posterURL: posterURL ?? self.posterURL
        )

        let playerItem = AVPlayerItem(asset: asset)
        audioGainController.reset(for: player.currentItem)
        if player.currentItem == nil {
            player = AVPlayer(playerItem: playerItem)
        } else {
            player.replaceCurrentItem(with: playerItem)
        }
        player.isMuted = isMuted
        installAudioVolumePipeline()
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible

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

    func schedulePlaybackStart(url: URL, subtitleURL: URL?, useTransition: Bool) {
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

    func startPlayback(subtitleURL: URL?) {
        setupObservers()
        activateMediaCommands()
        scheduleWindowAutosizeRetries()
        if isStreamingTorrent {
            startStreamBufferPolling()
        }
        if let subtitleURL {
            loadSubtitleStream(from: subtitleURL)
        } else {
            cancelSubtitleWork()
        }
        beginPlaybackFromUserIntent(restartTorrentAtEdges: false)
    }

    /// Single path for user-initiated playback — initial load and resume after pause.
    func beginPlaybackFromUserIntent(restartTorrentAtEdges: Bool) {
        if playbackRate <= 0 {
            playbackRate = 1.0
        }
        if restartTorrentAtEdges,
           pendingResumePosition == nil,
           streamsFromLocalTorrentServer,
           shouldRestartTorrentStreamFromBeginning() {
            let atStart = currentTime < 1
            let atEnd = duration > 0 && currentTime >= max(0, duration - 3)
            if atStart || atEnd {
                seek(to: 0)
            }
        }

        userWantsPlayback = true
        isPlaying = true
        lastPlaybackResumeAttempt = .distantPast

        if pendingResumePosition != nil {
            isBuffering = true
            tryApplyPendingResume()
            updateBufferingState()
            publishNowPlayingIfNeeded(force: true)
            return
        }

        player.playImmediately(atRate: Float(playbackRate))
        updateBufferingState()
        publishNowPlayingIfNeeded(force: true)
    }

    func revealPlayerWithTransition(onRevealed: @escaping () -> Void) {
        presentationTransitionTask?.cancel()
        capturePrePlayerWindowFrame()
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

    /// Replaces the HLS item after ffmpeg restarts from a mid-stream seek (`-ss`).
    /// - Parameters:
    ///   - url: The HLS playlist URL served by the local cache server.
    ///   - time: The **movie** time the user wants to seek to (e.g. 5400s).
    ///   - hlsOffset: The timeline offset — the `-ss` value passed to ffmpeg (e.g. 5370s).
    ///     The HLS stream starts at 0 but represents content starting at `hlsOffset` in the movie.
    public func reloadStreamingHLSPlaylist(_ url: URL, seekTo time: Double, hlsOffset: Double) {
        isRestartingStreamingRemux = true
        pendingResumePosition = nil
        pendingUserSeekTime = time
        initialSeekApplied = true
        isBuffering = true
        currentTime = time
        peakPlaybackTime = max(peakPlaybackTime, time)
        hlsStreamTimelineOffset = hlsOffset

        let assetOptions: [String: Any] = [
            AVURLAssetAllowsExpensiveNetworkAccessKey: true,
            AVURLAssetAllowsCellularAccessKey: true,
            AVURLAssetAllowsConstrainedNetworkAccessKey: true,
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
        ]
        let asset = AVURLAsset(url: url, options: assetOptions)
        let playerItem = AVPlayerItem(asset: asset)
        audioGainController.reset(for: player.currentItem)
        player.replaceCurrentItem(with: playerItem)
        player.isMuted = isMuted
        installAudioVolumePipeline()

        // Seek to the position within the HLS stream (movie time minus HLS start offset).
        let hlsRelativeTime = time - hlsOffset
        PlaybackLog.log("[MKVHLS] reload playlist after seek restart → movie \(Int(time))s hlsOffset=\(Int(hlsOffset))s hlsRelative=\(Int(hlsRelativeTime))s")

        setupObservers()
        let target = CMTime(seconds: hlsRelativeTime, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRestartingStreamingRemux = false
                self.pendingUserSeekTime = nil
                self.currentTime = time
                if self.userWantsPlayback {
                    self.player.playImmediately(atRate: Float(self.playbackRate))
                }
                self.updateBufferingState()
            }
        }
    }

}
