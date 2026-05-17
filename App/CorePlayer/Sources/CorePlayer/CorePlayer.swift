import AVFoundation
import Combine
import SwiftUI

public enum PlayerHDRType: String, Sendable, Codable {
    case hdr = "HDR"
    case hdr10 = "HDR10"
    case hdr10Plus = "HDR10+"
    case dolbyVision = "Dolby Vision"
    case dolbyVisionWithHDR10 = "DV-HDR10"
}

@MainActor
@Observable
public final class PlayerState {
    public var player: AVPlayer
    public var title: String
    public var movieId: Int
    public var isPresented: Bool
    public var isPlaying: Bool
    public var currentTime: Double
    public var duration: Double
    public var volume: Float
    public var isMuted: Bool
    public var playbackRate: Double
    public var showsControls: Bool
    public var subtitleURL: URL?
    public var activeSubtitleTrack: Int
    public var currentSubtitleText: String = ""
    public var hdrType: PlayerHDRType? = nil
    public var onPositionUpdate: ((Int, Double, Double) -> Void)?

    private var timeObserver: Any?
    private var periodObserver: Any?
    private var subtitleStream: SubtitleStream?
    private var subtitleLoadTask: Task<Void, Never>?
    private var cancellables: [AnyCancellable] = []

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

    public func load(url: URL, title: String, movieId: Int = 0, subtitleURL: URL? = nil, hdrType: PlayerHDRType? = nil) {
        self.title = title
        self.movieId = movieId
        self.subtitleURL = subtitleURL
        self.hdrType = hdrType
        
        let playerItem = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: playerItem)
        isPresented = true
        showsControls = true
        setupObservers()

        if let subtitleURL {
            loadSubtitleStream(from: subtitleURL)
        }
        
        player.play()
        isPlaying = true
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
        removeObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPresented = false
        isPlaying = false
        currentTime = 0
        duration = 0
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
            periodObserver = currentItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    self?.duration = item.asset.duration.seconds
                }
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

    private func removeObservers() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        periodObserver = nil
        cancellables.removeAll()
    }
}

public struct AVPlayerLayerView: NSViewRepresentable {
    private let player: AVPlayer

    public init(player: AVPlayer) {
        self.player = player
    }

    public func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.wantsExtendedDynamicRangeContent = true
        return view
    }

    public func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        nsView.playerLayer.player = player
    }
}

public final class PlayerContainerView: NSView {
    public let playerLayer = AVPlayerLayer()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
    }

    required init?(coder: NSCoder) {
        nil
    }
}

public struct PlayerView: View {
    @Bindable private var state: PlayerState
    @State private var controlFadeTask: Task<Void, Never>?
    @State private var isHoveringHUD: Bool = false

    public init(state: PlayerState) {
        self.state = state
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Native AVPlayer rendering layer
            AVPlayerLayerView(player: state.player)
                .ignoresSafeArea()

            subtitleOverlay

            // Beautiful, floating glassmorphic IINA top bar
            topHUD
                .opacity(state.showsControls ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: state.showsControls)

            // Center play/pause temporary indicator overlay
            centerIndicator

            // Stunning, floating glassmorphic IINA control pod
            bottomHUD
                .opacity(state.showsControls ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: state.showsControls)
        }
        .focusable()
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
            HStack(spacing: 12) {
                // Sleek Close button
                Button {
                    state.dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)

                // Title
                Text(state.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                // Dynamic glowing HDR / Dolby Vision badges just like IINA
                if let hdr = state.hdrType {
                    switch hdr {
                    case .dolbyVision, .dolbyVisionWithHDR10:
                        HStack(spacing: 4) {
                            Text("Dolby")
                                .font(.system(size: 9, weight: .bold))
                            Text("Vision")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.5, green: 0.1, blue: 0.8), Color(red: 0.2, green: 0.3, blue: 0.9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: Capsule()
                        )
                        .shadow(color: Color(red: 0.5, green: 0.1, blue: 0.8).opacity(0.6), radius: 3)
                    case .hdr, .hdr10, .hdr10Plus:
                        Text(hdr.rawValue)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 1.0, green: 0.8, blue: 0.1), Color(red: 0.9, green: 0.6, blue: 0.0)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: Capsule()
                            )
                            .shadow(color: Color(red: 1.0, green: 0.8, blue: 0.1).opacity(0.5), radius: 3)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            .padding(.top, 20)
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var centerIndicator: some View {
        Group {
            if !state.isPlaying && !state.showsControls {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.6))
                    .shadow(color: .black.opacity(0.3), radius: 8)
                    .transition(.scale.combined(with: .opacity))
                    .animation(.spring(), value: state.isPlaying)
            }
        }
    }

    private var bottomHUD: some View {
        VStack {
            Spacer()

            VStack(spacing: 12) {
                // Sleek Floating Scrubber
                scrubber

                // Control panel rows
                HStack(spacing: 24) {
                    // Left group: Volume controls
                    HStack(spacing: 8) {
                        Button {
                            state.toggleMute()
                        } label: {
                            Image(systemName: muteIcon)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(HUDButtonStyle())

                        VolumeSlider(volume: state.volume) { newValue in
                            state.setVolume(newValue)
                        }
                        .frame(width: 80)
                    }

                    Spacer()

                    // Center group: Main playback controls
                    HStack(spacing: 18) {
                        Button {
                            state.seek(by: -10)
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 15))
                        }
                        .buttonStyle(HUDButtonStyle())

                        Button {
                            state.togglePlayback()
                        } label: {
                            Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 20))
                        }
                        .buttonStyle(HUDPrimaryButtonStyle())

                        Button {
                            state.seek(by: 10)
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 15))
                        }
                        .buttonStyle(HUDButtonStyle())
                    }

                    Spacer()

                    // Right group: Speed, Subtitle, Fullscreen
                    HStack(spacing: 12) {
                        Button {
                            state.cyclePlaybackRate()
                        } label: {
                            Text("\(state.playbackRate, specifier: "%.2g")x")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                        }
                        .buttonStyle(HUDButtonStyle())

                        Button {
                            state.toggleSubtitle()
                        } label: {
                            Image(systemName: state.activeSubtitleTrack >= 0 ? "captions.bubble.fill" : "captions.bubble")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(HUDButtonStyle())
                        .disabled(state.subtitleURL == nil && state.activeSubtitleTrack < 0)

                        Button {
                            toggleFullScreen()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(HUDButtonStyle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 6)
            .frame(maxWidth: 640)
            .padding(.bottom, 24)
            .onHover { hovering in
                isHoveringHUD = hovering
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var scrubber: some View {
        HStack(spacing: 12) {
            Text(formatTime(state.currentTime))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))

            Slider(value: Binding(
                get: { state.currentTime },
                set: { state.seek(to: $0) }
            ), in: 0...max(state.duration, 0.01)) {
                Text("Seek")
            }
            .tint(.white)
            .controlSize(.mini)

            Text(formatTime(state.duration))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var muteIcon: String {
        if state.isMuted || state.volume == 0 {
            return "speaker.slash.fill"
        } else if state.volume < 0.5 {
            return "speaker.fill"
        } else {
            return "speaker.wave.3.fill"
        }
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
