@preconcurrency import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


@MainActor
@Observable
public final class PlayerState {
    /// Matches CoreStreaming `TorrentPlaybackURLScheme` (CorePlayer cannot import CoreStreaming).
    static func isTorrentResourceLoaderURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "mbtorrenthttps" || scheme == "mbtorrent"
    }

    public var player: AVPlayer
    public var title: String
    public var seriesName: String = ""
    public var episodeTitle: String? = nil
    public var videoGravity: AVLayerVideoGravity = .resizeAspect
    public var movieId: Int
    /// Info hash for the active torrent stream (on-device scrubber buffer cache).
    public var activeTorrentInfoHash: String?
    /// Poster shown in Control Center / Now Playing when set.
    public var posterURL: URL?
    public var isPresented: Bool
    /// True when the player was opened for a torrent stream (not trailer/clip-only).
    public var isStreamingTorrent: Bool = false
    /// Full-screen player chrome is hidden while playback continues (e.g. PiP + browsing).
    public var isPlaybackChromeHidden: Bool = false
    /// When true, closing PiP (X) dismisses playback instead of restoring the in-app player.
    var dismissPlaybackWhenPiPCloses: Bool = false
    /// Fades the player layer in after app chrome has faded out.
    public var isPlayerRevealed: Bool
    public var isPlaying: Bool
    /// True while AVPlayer is waiting for media data (initial load or rebuffer).
    public var isBuffering: Bool = false
    /// Shown under the buffering spinner while the torrent stream is preparing.
    public var bufferingDetail: String?
    /// Non-blocking HDR/Atmos validation notice (permissive remux mode).
    public var playbackQualityWarning: String?
    public var currentTime: Double = 0
    public var duration: Double = 0
    public var bufferedTimeRanges: [ClosedRange<Double>] = []
    /// Furthest timeline reached this session — scrubber keeps a dim “already visited” span after seeking back.
    public var peakPlaybackTime: Double = 0
    /// When set (torrent streams), polled to merge disk-backed ranges into the scrubber.
    public var streamBufferTimeRangesProvider: (@MainActor () async -> [ClosedRange<Double>])?
    public var volume: Float = 1.0
    public var isMuted: Bool = false
    public var playbackRate: Double = 1.0
    public var isFastScanning = false
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
    /// Latest HDR/DV/Atmos probe (HLS manifest and/or AVPlayer track).
    public var streamQualityDiagnostics: StreamQualityDiagnostics?
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
    /// Shown in the sidebar and on-video when a subtitle file is being fetched or parsed.
    public var subtitleLoadProgress: SubtitleLoadProgress?
    public var onSelectSubtitle: (@MainActor (PlayerSubtitleOption) async -> Void)?
    public var onRefreshSubtitles: (@MainActor () async -> Void)?
    /// Downloads and loads the default English subtitle when enabling captions without a file yet.
    public var onEnsureSubtitleSelected: (@MainActor () async -> Void)?
    /// Fired when AVPlayer exposes `.legible` subtitle tracks on the current item.
    public var onEmbeddedLegibleTracksDiscovered: (@MainActor ([EmbeddedLegibleTrack]) -> Void)?
    /// Refreshes the torrent export slice used for ffmpeg subtitle extraction while streaming.
    public var resolveEmbeddedMediaURL: (() async -> URL?)?
    /// Captions rendered by AVPlayer in the video layer (not the custom SRT overlay).
    public var usesAVPlayerEmbeddedSubtitles = false
    /// Seek here once the item is `readyToPlay` (continue watching).
    public var pendingResumePosition: Double?
    /// User scrubbed ahead on a torrent stream — hold UI at target until data arrives.
    var pendingUserSeekTime: Double?
    var isApplyingPendingUserSeek = false
    var lastPendingSeekRetry = Date.distantPast
    var isApplyingResumeSeek = false
    var initialSeekApplied = false
    /// Reprioritize torrent piece downloads toward a timeline position (set during streaming).
    public var onPrioritizeTorrentPlayback: (@MainActor (Double) async -> Void)?
    /// Restart live ffmpeg HLS remux when the user seeks ahead of generated segments.
    public var onRestartStreamingHLSSeek: (@MainActor (Double) async -> Void)?
    var isRestartingStreamingRemux = false
    /// Persists scrubber buffer spans for the active torrent (wired by MovieBoxCore).
    public var onPersistStreamBufferRanges: (
        @MainActor (_ tmdbId: Int, _ infoHash: String, _ duration: Double, _ ranges: [ClosedRange<Double>]) -> Void
    )?
    /// Position to report for continue-watching (includes in-flight scrubber targets).
    public var reportedPlaybackPosition: Double {
        pendingUserSeekTime ?? currentTime
    }

    var legibleSelectionGroup: AVMediaSelectionGroup?

    // Picture in Picture
    public var isPictureInPictureActive: Bool = false
    public var isPictureInPicturePossible: Bool = false
    var pipController: AVPictureInPictureController?
    var pipDelegate: PlayerPiPDelegate?
    weak var pipPlayerLayer: AVPlayerLayer?
    var pipPossibleObservation: NSKeyValueObservation?
    var fastScanBackwardTask: Task<Void, Never>?
    var fastScanIsForward = false
    var wasPlayingBeforeFastScan = false
    var hudPillDismissTask: Task<Void, Never>?
    var hudPillDismissGeneration: UInt64 = 0
    var qualityBadgePillShownForCurrentItem = false
    /// When set at `load()`, remux-verified badges are not replaced by AVPlayer track probing.
    var qualityBadgesLockedFromPrepare = false
    /// Full title length (e.g. TMDB runtime) — AVPlayer HLS may report only remuxed-so-far (~minutes).
    var trustedDurationSeconds: Double?

    var timeObserver: Any?
    var itemStatusObserver: NSKeyValueObservation?
    var playbackBufferObserver: NSKeyValueObservation?
    var presentationSizeObserver: NSKeyValueObservation?
    var playbackEndObserver: NSObjectProtocol?
    var thumbnailService: ThumbnailService?
    var subtitleStream: SubtitleStream?
    var subtitleLoadTask: Task<Void, Never>?
    var subtitleUpdateTask: Task<Void, Never>?
    var cancellables: [AnyCancellable] = []
    var observedPlayerItem: AVPlayerItem?

    var lastPositionReportTime: Date = .distantPast
    var lastReportedPosition: Double = -1
    var lastSubtitleSyncTime: Double = -1
    public var cachedStreamBufferRanges: [ClosedRange<Double>] = []
    var streamBufferPollTask: Task<Void, Never>?
    var mediaCommandCenter: PlayerMediaCommandCenter?
    var lastNowPlayingPublishTime: Date = .distantPast
    /// User chose play (not paused) — used to auto-resume after torrent rebuffer.
    var userWantsPlayback = false
    var lastPlaybackResumeAttempt = Date.distantPast
    var playbackLikelyToKeepUpObserver: NSKeyValueObservation?

    var previousWindowFrame: NSRect? = nil
    var hasResizedForCurrentVideo = false
    var windowAutosizeTask: Task<Void, Never>?
    var presentationTransitionTask: Task<Void, Never>?
    var lastPlaybackLoad: StoredPlaybackLoad?
    var streamsFromLocalTorrentServer = false
    /// Remuxed HLS loopback — AVPlayer reports buffer; torrent byte ranges duplicate the scrubber bar.
    public var isHLSTorrentPlayback = false
    weak var pipHostView: PlayerContainerView?

    struct StoredPlaybackLoad: Sendable {
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
        let posterURL: URL?
    }

    static let positionReportInterval: TimeInterval = 5
    static let positionReportMinimumDelta: Double = 8
    static let timeObserverInterval: TimeInterval = 0.25
    static let subtitleSyncInterval: TimeInterval = 0.2

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
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        player.preventsDisplaySleepDuringVideoPlayback = true
    }
}

extension PlayerState: @unchecked Sendable {}
