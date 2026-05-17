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

actor ThumbnailService {
    private let generator: AVAssetImageGenerator

    init(asset: AVAsset) {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 180)
        self.generator = gen
    }

    func generateImage(at time: CMTime) async throws -> CGImage {
        return try await withCheckedThrowingContinuation { continuation in
            let timeValue = NSValue(time: time)
            generator.generateCGImagesAsynchronously(forTimes: [timeValue]) { _, image, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let image = image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: NSError(domain: "ThumbnailError", code: 0, userInfo: nil))
                }
            }
        }
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
    public var isPlaying: Bool
    public var currentTime: Double = 0
    public var duration: Double = 0
    public var volume: Float = 1.0
    public var isMuted: Bool = false
    public var playbackRate: Double = 1.0
    public var showsControls: Bool = false
    public var subtitleURL: URL? = nil
    public var activeSubtitleTrack: Int = 0
    public var currentSubtitleText: String = ""
    
    public var hdrType: PlayerHDRType? = nil
    public var errorMessage: String? = nil
    public var onPositionUpdate: ((Int, Double, Double) -> Void)?

    // Picture in Picture
    public var isPictureInPictureActive: Bool = false
    public var isPictureInPicturePossible: Bool = false
    private var pipController: AVPictureInPictureController?
    private var pipDelegate: PlayerPiPDelegate?

    private var timeObserver: Any?
    private var periodObserver: Any?
    private var presentationSizeObserver: NSKeyValueObservation?
    private var thumbnailService: ThumbnailService?
    private var subtitleStream: SubtitleStream?
    private var subtitleLoadTask: Task<Void, Never>?
    private var cancellables: [AnyCancellable] = []
    
    private var hasResizedForCurrentVideo: Bool = false
    private var previousWindowFrame: NSRect? = nil

    public init(player: AVPlayer = AVPlayer(), title: String = "", movieId: Int = 0, isPresented: Bool = false) {
        self.player = player
        self.title = title
        self.movieId = movieId
        self.isPresented = isPresented
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

    public func load(url: URL, title: String, movieId: Int = 0, subtitleURL: URL? = nil, hdrType: PlayerHDRType? = nil, episodeTitle: String? = nil) {
        print("[DEBUG] PlayerState.load() called")
        print("[DEBUG] - Title: \(title)")
        print("[DEBUG] - URL: \(url.absoluteString)")
        print("[DEBUG] - Movie ID: \(movieId)")
        print("[DEBUG] - Subtitle URL: \(subtitleURL?.absoluteString ?? "None")")
        print("[DEBUG] - HDR Type: \(hdrType?.rawValue ?? "None")")
        print("[DEBUG] - Episode Title: \(episodeTitle ?? "None")")

        self.title = title
        self.movieId = movieId
        self.subtitleURL = subtitleURL
        self.hdrType = hdrType
        self.errorMessage = nil
        self.videoGravity = .resizeAspect // Reset to default

        if let ep = episodeTitle {
            self.seriesName = title
            self.episodeTitle = ep
        } else {
            let parsed = PlayerState.parseTVShowMetadata(from: title)
            self.seriesName = parsed.seriesName
            self.episodeTitle = parsed.episodeName
        }
        
        let asset = AVURLAsset(url: url)
        self.thumbnailService = ThumbnailService(asset: asset)
        
        let playerItem = AVPlayerItem(asset: asset)
        self.player = AVPlayer(playerItem: playerItem)
        isPresented = true
        showsControls = true
        hasResizedForCurrentVideo = false
        setupObservers()

        if let subtitleURL {
            loadSubtitleStream(from: subtitleURL)
        }
        
        print("[DEBUG] Calling player.play()")
        player.play()
        isPlaying = true
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
        if let window = NSApplication.shared.keyWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        if let prevFrame = previousWindowFrame, let window = NSApplication.shared.keyWindow, !window.styleMask.contains(.fullScreen) {
            window.setFrame(prevFrame, display: true, animate: true)
            previousWindowFrame = nil
        }
        hasResizedForCurrentVideo = false

        removeObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPresented = false
        isPlaying = false
        currentTime = 0
        duration = 0
        errorMessage = nil
    }

    public func setupPiP(with playerLayer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        print("[DEBUG] Setting up AVPictureInPictureController")
        let delegate = PlayerPiPDelegate(state: self)
        self.pipDelegate = delegate
        let controller = AVPictureInPictureController(playerLayer: playerLayer)
        controller?.delegate = delegate
        self.pipController = controller
        self.isPictureInPicturePossible = controller?.isPictureInPicturePossible ?? false
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
        isPlaying = true
    }

    public func generateThumbnail(for time: Double) async -> NSImage? {
        guard let service = thumbnailService else { return nil }
        do {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            let cgImage = try await service.generateImage(at: cmTime)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            return nil
        }
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func seek(to time: Double) {
        let clamped = max(0, min(time, duration))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
        updateSubtitle(at: clamped)
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
        playbackRate = rate
        player.rate = Float(rate)
    }

    public func cyclePlaybackRate() {
        let rates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
        if let idx = rates.firstIndex(of: playbackRate) {
            let next = rates[(idx + 1) % rates.count]
            setPlaybackRate(next)
        }
    }

    private func setupObservers() {
        print("[DEBUG] setupObservers() started")
        removeObservers()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds
                self?.updateSubtitle(at: time.seconds)
                if let movieId = self?.movieId, self?.movieId != 0,
                   let duration = self?.duration, duration > 0 {
                    self?.onPositionUpdate?(movieId, time.seconds, duration)
                }
            }
        }

        if let currentItem = player.currentItem {
            duration = currentItem.asset.duration.seconds
            print("[DEBUG] Observing player item: \(currentItem)")
            periodObserver = currentItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    print("[DEBUG] PlayerItem status changed to: \(item.status.rawValue)")
                    if item.status == .failed {
                        print("[ERROR] PlayerItem failed! Error: \(String(describing: item.error?.localizedDescription))")
                        print("[ERROR] Underlying error details: \(String(describing: item.error))")
                        self?.errorMessage = item.error?.localizedDescription ?? "Playback failed. Please try a different source or format."
                    } else if item.status == .readyToPlay {
                        print("[DEBUG] PlayerItem ready to play! Duration: \(item.asset.duration.seconds)s")
                        self?.duration = item.asset.duration.seconds
                        self?.errorMessage = nil
                    }
                }
            }
            
            presentationSizeObserver = currentItem.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    let size = item.presentationSize
                    if size.width > 0 && size.height > 0 {
                        self?.resizeWindowToMatch(aspectRatio: size)
                    }
                }
            }
        } else {
            print("[WARNING] No currentItem found on player in setupObservers()")
        }

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                Task { @MainActor in
                    print("[DEBUG] TimeControlStatus changed to: \(status.rawValue)")
                    self?.isPlaying = (status == .playing)
                }
            }
            .store(in: &cancellables)
    }

    private func resizeWindowToMatch(aspectRatio: CGSize) {
        guard !hasResizedForCurrentVideo else { return }
        guard let window = NSApplication.shared.keyWindow, !window.styleMask.contains(.fullScreen) else { return }
        
        hasResizedForCurrentVideo = true
        
        let currentFrame = window.frame
        if previousWindowFrame == nil {
            previousWindowFrame = currentFrame
        }
        
        let ratio = aspectRatio.width / aspectRatio.height
        
        let newHeight = currentFrame.width / ratio
        
        if abs(currentFrame.height - newHeight) > 10 {
            var newFrame = currentFrame
            newFrame.size.height = newHeight
            newFrame.origin.y = currentFrame.origin.y + (currentFrame.height - newHeight) / 2
            
            window.setFrame(newFrame, display: true, animate: true)
        }
    }

    private func removeObservers() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        periodObserver = nil
        presentationSizeObserver = nil
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
    
    @State private var hoverTime: Double? = nil
    @State private var hoverX: CGFloat = 0
    @State private var hoverImage: NSImage? = nil
    @State private var hoverImageTask: Task<Void, Never>? = nil

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
                .animation(.easeOut(duration: 0.12), value: state.showsControls)

            // Center play/pause & seek overlay
            centerControls

            // Stunning, floating glassmorphic IINA control pod
            bottomHUD
                .opacity(state.showsControls ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: state.showsControls)

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
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            state.togglePlayback()
            resetControlFade()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            state.seek(by: -10)
            resetControlFade()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            state.seek(by: 10)
            resetControlFade()
            return .handled
        }
        .onKeyPress(.upArrow) {
            state.setVolume(min(1.0, state.volume + 0.1))
            resetControlFade()
            return .handled
        }
        .onKeyPress(.downArrow) {
            state.setVolume(max(0.0, state.volume - 0.1))
            resetControlFade()
            return .handled
        }
        .onKeyPress("m") {
            state.toggleMute()
            resetControlFade()
            return .handled
        }
        .onKeyPress(.escape) {
            state.dismiss()
            return .handled
        }
        .onKeyPress("f") {
            toggleFullScreen()
            resetControlFade()
            return .handled
        }
        .onKeyPress("s") {
            state.toggleSubtitle()
            resetControlFade()
            return .handled
        }
        .overlay {
            MouseTrackingView(onMove: resetControlFade)
        }
        .ignoresSafeArea()
        .task {
            resetControlFade()
        }
    }

    private var subtitleOverlay: some View {
        VStack {
            Spacer()

            if !state.currentSubtitleText.isEmpty && state.activeSubtitleTrack >= 0 {
                Text(state.currentSubtitleText)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 4, x: 0, y: 2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
                    .padding(.bottom, 120) // Raised slightly to sit elegantly above the new floating HUD
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: state.currentSubtitleText)
            }
        }
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
                            .adaptiveGlass(cornerRadius: 15, strength: .thick)
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
                            toggleFullScreen()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .adaptiveGlass(cornerRadius: 16, strength: .thick)
                }

                Spacer()

                // Top-Right Group: Volume Capsule
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
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .adaptiveGlass(cornerRadius: 18, strength: .thick)
            }
            .padding(.top, 24)
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var centerControls: some View {
        HStack(spacing: 28) {
            // Seek Back Button
            Button {
                state.seek(by: -15)
                resetControlFade()
                skipBackTrigger += 1
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.rotate, value: skipBackTrigger)
                    .frame(width: 52, height: 52)
                    .adaptiveGlass(cornerRadius: 26, strength: .thick)
            }
            .buttonStyle(CenterHUDButtonStyle())

            // Center Play / Pause Button
            Button {
                state.togglePlayback()
                resetControlFade()
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 72, height: 72)
                    .adaptiveGlass(cornerRadius: 36, strength: .thick)
            }
            .buttonStyle(CenterHUDButtonStyle())
            .animation(.spring(response: 0.05, dampingFraction: 0.95), value: state.isPlaying)

            // Seek Forward Button
            Button {
                state.seek(by: 15)
                resetControlFade()
                skipForwardTrigger += 1
            } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.rotate, value: skipForwardTrigger)
                    .frame(width: 52, height: 52)
                    .adaptiveGlass(cornerRadius: 26, strength: .thick)
            }
            .buttonStyle(CenterHUDButtonStyle())
        }
        .scaleEffect(state.showsControls ? 1.0 : 0.9)
        .opacity(state.showsControls ? 1.0 : 0.0)
        .animation(.spring(response: 0.08, dampingFraction: 0.92), value: state.showsControls)
    }

    private var bottomHUD: some View {
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
                HStack(spacing: 12) {
                    Text(formatTime(state.currentTime))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))

                    CustomSlider(
                        value: Binding(
                            get: { state.currentTime },
                            set: { state.seek(to: $0) }
                        ),
                        range: 0...max(state.duration, 0.01),
                        onHoverTime: { time, x in
                            if let time = time, let x = x {
                                hoverTime = time
                                hoverX = x
                                
                                hoverImageTask?.cancel()
                                hoverImageTask = Task {
                                    if let img = await state.generateThumbnail(for: time) {
                                        if !Task.isCancelled {
                                            hoverImage = img
                                        }
                                    }
                                }
                            } else {
                                hoverTime = nil
                                hoverImageTask?.cancel()
                                hoverImageTask = nil
                            }
                        }
                    )
                    .overlay(alignment: .bottomLeading) {
                        if let hTime = hoverTime {
                            VStack(spacing: 8) {
                                if let img = hoverImage {
                                    Image(nsImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 160)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .shadow(color: .black.opacity(0.5), radius: 10, y: 5)
                                } else {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(.black.opacity(0.5))
                                        .frame(width: 160, height: 90)
                                        .overlay(ProgressView().controlSize(.small))
                                }
                                
                                Text(formatTime(hTime))
                                    .font(.system(size: 11, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.black.opacity(0.6), in: Capsule())
                            }
                            .offset(x: hoverX - 80, y: -24)
                            .allowsHitTesting(false)
                        }
                    }

                    Text(formatRemainingTime())
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .adaptiveGlass(cornerRadius: 18, strength: .thick)
                .frame(maxWidth: .infinity)

                // Subtitle, Audio & Video Aspect Selectors Capsule
                HStack(spacing: 18) {
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
                .adaptiveGlass(cornerRadius: 16, strength: .thick)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .onHover { hovering in
                isHoveringHUD = hovering
            }
        }
        .frame(maxWidth: .infinity)
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

    private func toggleFullScreen() {
        guard let window = NSApplication.shared.keyWindow else { return }
        window.toggleFullScreen(nil)
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
