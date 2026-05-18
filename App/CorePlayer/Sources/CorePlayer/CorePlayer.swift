import AVFoundation
import Combine
import SwiftUI
import AppKit
import AVKit

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
    public var player: AVPlayer
    public var title: String
    public var seriesName: String = ""
    public var episodeTitle: String? = nil
    public var videoGravity: AVLayerVideoGravity = .resizeAspect
    public var movieId: Int
    public var isPresented: Bool
    /// Fades the player layer in after app chrome has faded out.
    public var isPlayerRevealed: Bool
    public var isPlaying: Bool
    public var currentTime: Double = 0
    public var duration: Double = 0
    public var volume: Float = 1.0
    public var isMuted: Bool = false
    public var playbackRate: Double = 1.0
    public private(set) var isFastScanning = false
    public var showsControls: Bool = false
    public var subtitleURL: URL? = nil
    public var activeSubtitleTrack: Int = 0
    public var currentSubtitleText: String = ""
    public var currentSubtitleCueID: UUID?
    public var subtitleAppearance: SubtitleAppearance = .cinematic
    public var subtitleFontSize: CGFloat = 20
    
    public var hdrType: PlayerHDRType? = nil
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

    // Picture in Picture
    public var isPictureInPictureActive: Bool = false
    public var isPictureInPicturePossible: Bool = false
    private var pipController: AVPictureInPictureController?
    private var pipDelegate: PlayerPiPDelegate?
    private var fastScanBackwardTask: Task<Void, Never>?
    private var playbackRateBeforeFastScan: Double = 1.0

    private var timeObserver: Any?
    private var itemStatusObserver: NSKeyValueObservation?
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
        self.volume = 1.0
        self.isMuted = false
        self.playbackRate = 1.0
        self.showsControls = true
        self.subtitleURL = nil
        self.activeSubtitleTrack = -1
        self.hdrType = nil
    }

    public func load(
        url: URL,
        title: String,
        movieId: Int = 0,
        subtitleURL: URL? = nil,
        hdrType: PlayerHDRType? = nil,
        subtitleAppearance: SubtitleAppearance = .cinematic,
        subtitleFontSize: CGFloat = 20,
        episodeTitle: String? = nil,
        episodes: [PlayerEpisode] = [],
        currentEpisodeIndex: Int? = nil
    ) {
        stopPlaybackResources()

        self.title = title
        self.movieId = movieId
        self.subtitleURL = subtitleURL
        self.hdrType = hdrType
        self.subtitleAppearance = subtitleAppearance
        self.subtitleFontSize = subtitleFontSize
        self.errorMessage = nil
        if !episodes.isEmpty {
            self.episodes = episodes
            self.currentEpisodeIndex = currentEpisodeIndex
        }
        
        self.videoGravity = .resizeAspect // Reset to default
        hasResizedForCurrentVideo = false

        if let ep = episodeTitle {
            self.seriesName = title
            self.episodeTitle = ep
        } else {
            let parsed = PlayerState.parseTVShowMetadata(from: title)
            self.seriesName = parsed.seriesName
            self.episodeTitle = parsed.episodeName
        }
        
        lastPositionReportTime = .distantPast
        lastReportedPosition = -1
        lastSubtitleSyncTime = -1

        let asset = AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "User-Agent": "MovieBox/1.0 (Macintosh; AVFoundation)",
                ],
                AVURLAssetAllowsExpensiveNetworkAccessKey: true,
                AVURLAssetAllowsCellularAccessKey: true,
                AVURLAssetAllowsConstrainedNetworkAccessKey: true,
            ] as [String: Any]
        )
        if let existing = thumbnailService {
            Task { await existing.clearCache() }
        }
        thumbnailService = ThumbnailService(asset: asset)

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
        setupObservers()

        if let subtitleURL {
            loadSubtitleStream(from: subtitleURL)
        } else {
            cancelSubtitleWork()
        }

        if isPresented && isPlayerRevealed {
            player.play()
            player.rate = Float(playbackRate)
            isPlaying = true
            return
        }

        revealPlayerWithTransition()
    }

    private func revealPlayerWithTransition() {
        presentationTransitionTask?.cancel()
        isPresented = true
        isPlayerRevealed = false

        presentationTransitionTask = Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.38)) {}
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.38)) {
                isPlayerRevealed = true
            }
            player.play()
            player.rate = Float(playbackRate)
            isPlaying = true
        }
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
        Task {
            guard let group = try? await asset.loadMediaSelectionGroup(for: .legible) else { return }
            await MainActor.run {
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
        if activeSubtitleTrack >= 0 {
            activeSubtitleTrack = -1
            currentSubtitleText = ""
        } else if subtitleURL != nil {
            if subtitleStream == nil, let url = subtitleURL {
                loadSubtitleStream(from: url)
            } else {
                activeSubtitleTrack = 0
                updateSubtitle(at: currentTime)
            }
        }
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
        isPlayerRevealed = false
        isPresented = false
        currentTime = 0
        duration = 0
        errorMessage = nil
        episodes = []
        currentEpisodeIndex = nil
        isEpisodesSidebarOpen = false
        seriesName = ""
        episodeTitle = nil
        hdrType = nil
        playbackSources = []
        selectedPlaybackSourceID = nil
        isSwitchingSource = false
        onSelectPlaybackSource = nil
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
            isPictureInPictureActive = true
            controller.startPictureInPicture()
        }
    }

    public func togglePlayback() {
        if player.timeControlStatus == .playing {
            pause()
        } else {
            play()
        }
    }

    public func play() {
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
        player.pause()
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
    }

    public func startFastScan(forward: Bool) {
        guard isPresented, !isFastScanning else { return }
        isFastScanning = true
        playbackRateBeforeFastScan = playbackRate > 0 ? playbackRate : 1.0
        fastScanBackwardTask?.cancel()

        if forward {
            player.rate = 2.0
            playbackRate = 2.0
            play()
        } else {
            player.rate = -1.5
            playbackRate = -1.5
            play()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                if player.rate >= 0 {
                    player.rate = 0
                    startBackwardSeekRepeat()
                }
            }
        }
    }

    public func stopFastScan() {
        guard isFastScanning else { return }
        isFastScanning = false
        fastScanBackwardTask?.cancel()
        fastScanBackwardTask = nil
        let restore = playbackRateBeforeFastScan > 0 ? playbackRateBeforeFastScan : 1.0
        playbackRate = restore
        player.rate = Float(restore)
        if player.timeControlStatus != .playing, isPlaying {
            play()
        }
    }

    private func startBackwardSeekRepeat() {
        fastScanBackwardTask?.cancel()
        fastScanBackwardTask = Task {
            while !Task.isCancelled {
                seek(by: -10)
                try? await Task.sleep(for: .milliseconds(350))
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
            currentTime = seconds
            updateSubtitle(at: seconds)

            guard movieId != 0, duration > 0 else { return }
            let now = Date()
            let positionDelta = abs(seconds - lastReportedPosition)
            let elapsed = now.timeIntervalSince(lastPositionReportTime)
            guard elapsed >= Self.positionReportInterval || positionDelta >= Self.positionReportMinimumDelta else {
                return
            }
            lastPositionReportTime = now
            lastReportedPosition = seconds
            onPositionUpdate?(movieId, seconds, duration)
        }

        guard let currentItem = player.currentItem else { return }
        observedPlayerItem = currentItem

        let itemDuration = currentItem.asset.duration.seconds
        if itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }

        itemStatusObserver = currentItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, item === self.observedPlayerItem else { return }
                if item.status == .failed {
                    self.errorMessage = item.error?.localizedDescription ?? "Playback failed. Please try a different source or format."
                } else if item.status == .readyToPlay {
                    let readyDuration = item.asset.duration.seconds
                    if readyDuration.isFinite, readyDuration > 0 {
                        self.duration = readyDuration
                    }
                    self.errorMessage = nil
                }
            }
        }

        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.playNextEpisode()
            }
        }

        presentationSizeObserver = currentItem.observe(\.presentationSize, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, item === self.observedPlayerItem else { return }
                let size = item.presentationSize
                guard size.width > 1, size.height > 1 else { return }
                self.resizeWindowToMatch(aspectRatio: size)
            }
        }

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                Task { @MainActor in
                    self?.isPlaying = (status == .playing)
                }
            }
            .store(in: &cancellables)
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
        layer as! AVPlayerLayer
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

public struct PlayerView: View {
    @Bindable private var state: PlayerState
    @State private var controlFadeTask: Task<Void, Never>?
    @State private var isHoveringHUD: Bool = false
    @State private var skipBackTrigger: Int = 0
    @State private var skipForwardTrigger: Int = 0
    @State private var isCommandHeld = false

    public init(state: PlayerState) {
        self.state = state
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

            // Beautiful, floating glassmorphic IINA top bar
            topHUD
                .opacity(state.showsControls ? 1 : 0)
                .animation(.easeOut(duration: 0.06), value: state.showsControls)

            // Center play/pause & seek overlay
            centerControls

            // Stunning, floating glassmorphic IINA control pod
            bottomHUD
                .opacity(state.showsControls ? 1 : 0)
                .animation(.easeOut(duration: 0.06), value: state.showsControls)

            // Frosted glass error overlay
            if let errorMsg = state.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(.red)
                        .shadow(color: .red.opacity(0.35), radius: 8)
                    
                    Text("Playback Error")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                    
                    Text(errorMsg)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 16)
                    
                    HStack(spacing: 12) {
                        // Copy Logs Button
                        Button {
                            let assetURL = (state.player.currentItem?.asset as? AVURLAsset)?.url.absoluteString ?? "No URL"
                            let logText = """
                            Playback Error: \(state.errorMessage ?? "Unknown error")
                            URL: \(assetURL)
                            """
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(logText, forType: .string)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.on.doc.fill")
                                Text("Copy Logs")
                            }
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.12), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        // Close Player Red Button
                        Button {
                            state.dismiss()
                        } label: {
                            Text("Close Player")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 7)
                                .background(Color.red, in: Capsule())
                                .shadow(color: .red.opacity(0.35), radius: 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 20)
                .frame(maxWidth: 360)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 15, y: 8)
                .transition(.scale.combined(with: .opacity))
                .zIndex(8)
            }
        }
        .overlay {
            PlayerKeyboardCaptureView(
                state: state,
                onActivity: resetControlFade,
                onSkipBack: { skipBackTrigger += 1 },
                onSkipForward: { skipForwardTrigger += 1 },
                onCommandHeld: { isCommandHeld = $0 }
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

                // Top-Right Group: Volume + Episodes
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
                pulseTrigger: $skipForwardTrigger,
                onActivity: resetControlFade
            )
        }
        .scaleEffect(state.showsControls ? 1.0 : 0.9)
        .opacity(state.showsControls ? 1.0 : 0.0)
        .animation(.spring(response: 0.08, dampingFraction: 0.92), value: state.showsControls)
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
                    Text(formatTime(state.currentTime))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 44, alignment: .trailing)

                    ScrubberSlider(
                        value: Binding(
                            get: { state.currentTime },
                            set: { state.seek(to: $0) }
                        ),
                        range: 0...max(state.duration, 0.01),
                        formatTime: formatTime,
                        thumbnailProvider: { time, requestID in
                            await state.thumbnailImage(for: time, requestID: requestID)
                        }
                    )
                    .frame(maxWidth: .infinity)

                    Text(formatRemainingTime())
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 44, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .nativeGlassEffect()
                .frame(maxWidth: .infinity)

                // Quality, subtitles, rate, aspect
                HStack(spacing: 18) {
                    if state.hasMultiplePlaybackSources {
                        qualitySourceMenu
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

                    Button {
                        state.toggleSubtitle()
                    } label: {
                        Image(systemName: state.activeSubtitleTrack >= 0 ? "captions.bubble.fill" : "captions.bubble")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(state.activeSubtitleTrack >= 0 ? 1.0 : 0.85))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .disabled(state.subtitleURL == nil && state.activeSubtitleTrack < 0)

                    // Video Aspect / Zoom Gravity Button
                    Button {
                        state.cycleVideoGravity()
                    } label: {
                        Image(systemName: "aspectratio")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
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
        }
        .frame(maxWidth: .infinity)
    }
    
    private var qualitySourceMenu: some View {
        Menu {
            let grouped = Dictionary(grouping: state.playbackSources, by: \.groupLabel)
            ForEach(grouped.keys.sorted(), id: \.self) { group in
                Section(group) {
                    ForEach(grouped[group] ?? []) { source in
                        Button {
                            guard source.id != state.selectedPlaybackSourceID else { return }
                            resetControlFade()
                            Task {
                                await state.onSelectPlaybackSource?(source)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.title)
                                        .lineLimit(2)
                                    Text(source.detailLine)
                                        .font(.caption2)
                                }
                                Spacer()
                                if source.id == state.selectedPlaybackSourceID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(state.isSwitchingSource ? 0.5 : 0.9))
                    .symbolEffect(.pulse, isActive: state.isSwitchingSource)
                if state.isSwitchingSource {
                    ProgressView()
                        .controlSize(.mini)
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Switch quality or language")
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

    func makeNSView(context: Context) -> PlayerKeyboardNSView {
        let view = PlayerKeyboardNSView()
        view.state = state
        view.onActivity = onActivity
        view.onSkipBack = onSkipBack
        view.onSkipForward = onSkipForward
        view.onCommandHeld = onCommandHeld
        return view
    }

    func updateNSView(_ nsView: PlayerKeyboardNSView, context: Context) {
        nsView.state = state
        nsView.onActivity = onActivity
        nsView.onSkipBack = onSkipBack
        nsView.onSkipForward = onSkipForward
        nsView.onCommandHeld = onCommandHeld
        if state.isPresented {
            nsView.claimKeyboardFocus()
            onCommandHeld(NSEvent.modifierFlags.contains(.command))
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
    private var focusObserver: NSObjectProtocol?
    private var isCommandKeyHeld = false

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
        }
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
struct NativeGlassEffectModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect()
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12), lineWidth: 1))
        }
    }
}

extension View {
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

/*
================================================================================
FUTURE SwiftVLC IMPLEMENTATION (libVLC 4.0)
To enable, uncomment this block, comment out the AVPlayer-based PlayerState / PlayerView,
and uncomment SwiftVLC in Package.swift.
================================================================================

import Combine
import SwiftUI
import SwiftVLC

extension Duration {
    public var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

@MainActor
@Observable
public final class SwiftVLCPlayerState {
    public var player: Player
    public var title: String
    public var movieId: Int
    public var isPresented: Bool
    public var showsControls: Bool
    public var subtitleURL: URL?
    public var activeSubtitleTrack: Int
    public var currentSubtitleText: String = ""
    public var hdrType: PlayerHDRType? = nil
    public var onPositionUpdate: ((Int, Double, Double) -> Void)?

    private var subtitleStream: SubtitleStream?
    private var subtitleLoadTask: Task<Void, Never>?
    private var timeObserverTask: Task<Void, Never>?

    public init(player: Player = Player(), title: String = "", movieId: Int = 0, isPresented: Bool = false) {
        self.player = player
        self.title = title
        self.movieId = movieId
        self.isPresented = isPresented
        self.showsControls = true
        self.subtitleURL = nil
        self.activeSubtitleTrack = -1
        self.hdrType = nil
    }

    public var isPlaying: Bool {
        player.isPlaying
    }

    public var currentTime: Double {
        player.currentTime.seconds
    }

    public var duration: Double {
        player.duration?.seconds ?? 0.0
    }

    public var volume: Float {
        player.volume
    }

    public var isMuted: Bool {
        player.isMuted
    }

    public var playbackRate: Double {
        Double(player.rate)
    }

    public func load(url: URL, title: String, movieId: Int = 0, subtitleURL: URL? = nil, hdrType: PlayerHDRType? = nil) {
        self.title = title
        self.movieId = movieId
        self.subtitleURL = subtitleURL
        self.hdrType = hdrType
        
        try? player.play(url: url)
        isPresented = true
        showsControls = true

        setupTimeObserver()

        if let subtitleURL {
            loadSubtitleStream(from: subtitleURL)
        }
    }

    public func loadSubtitleStream(from url: URL) {
        subtitleURL = url
        subtitleLoadTask?.cancel()
        subtitleLoadTask = Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let stream = SubtitleStream()
                await stream.load(from: data)
                await MainActor.run {
                    self.subtitleStream = stream
                    self.activeSubtitleTrack = 0
                    updateSubtitle(at: self.currentTime)
                }
            } catch {
                NSLog("Failed to load subtitle stream: \(error)")
            }
        }
    }

    public func toggleSubtitle() {
        if activeSubtitleTrack >= 0 {
            activeSubtitleTrack = -1
            currentSubtitleText = ""
        } else if subtitleURL != nil {
            if subtitleStream == nil, let url = subtitleURL {
                loadSubtitleStream(from: url)
            } else {
                activeSubtitleTrack = 0
                updateSubtitle(at: currentTime)
            }
        }
    }

    public func updateSubtitle(at time: TimeInterval) {
        guard activeSubtitleTrack >= 0, let stream = subtitleStream else {
            currentSubtitleText = ""
            return
        }

        Task {
            if let cue = await stream.cue(at: time) {
                await MainActor.run {
                    self.currentSubtitleText = cue.text
                }
            } else {
                await MainActor.run {
                    self.currentSubtitleText = ""
                }
            }
        }
    }

    public func dismiss() {
        timeObserverTask?.cancel()
        player.stop()
        isPresented = false
    }

    public func togglePlayback() {
        if player.isPlaying {
            try? player.pause()
        } else {
            try? player.play()
        }
    }

    public func play() {
        try? player.play()
    }

    public func pause() {
        try? player.pause()
    }

    public func seek(to time: Double) {
        let clamped = max(0, min(time, duration))
        try? player.seek(to: .seconds(clamped))
        updateSubtitle(at: clamped)
    }

    public func seek(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    public func setVolume(_ value: Float) {
        player.volume = value
    }

    public func toggleMute() {
        player.isMuted.toggle()
    }

    public func setPlaybackRate(_ rate: Double) {
        player.rate = Float(rate)
    }

    public func cyclePlaybackRate() {
        let rates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
        if let idx = rates.firstIndex(of: playbackRate) {
            let next = rates[(idx + 1) % rates.count]
            setPlaybackRate(next)
        }
    }

    private func setupTimeObserver() {
        timeObserverTask?.cancel()
        timeObserverTask = Task {
            while !Task.isCancelled {
                let time = player.currentTime.seconds
                let dur = player.duration?.seconds ?? 0.0
                updateSubtitle(at: time)
                if movieId != 0, dur > 0 {
                    onPositionUpdate?(movieId, time, dur)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

public struct SwiftVLCPlayerView: View {
    @Bindable private var state: SwiftVLCPlayerState
    @State private var controlFadeTask: Task<Void, Never>?
    @State private var isHoveringHUD: Bool = false

    public init(state: SwiftVLCPlayerState) {
        self.state = state
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VideoView(state.player)
                .ignoresSafeArea()

            // Reuse same HUD bar overlays
        }
    }
}
*/
