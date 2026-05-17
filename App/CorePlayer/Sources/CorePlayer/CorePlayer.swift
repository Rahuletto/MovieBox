import AVFoundation
import Combine
import SwiftUI

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
    public var onPositionUpdate: ((Int, Double, Double) -> Void)?

    private var timeObserver: Any?
    private var periodObserver: Any?
    private var subtitleStream: SubtitleStream?
    private var subtitleLoadTask: Task<Void, Never>?

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
    }

    public func load(url: URL, title: String, movieId: Int = 0, subtitleURL: URL? = nil) {
        self.title = title
        self.movieId = movieId
        self.subtitleURL = subtitleURL
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        isPresented = true
        showsControls = true
        setupObservers()

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

    private var cancellables: [AnyCancellable] = []
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

    public init(state: PlayerState) {
        self.state = state
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AVPlayerLayerView(player: state.player)
                .ignoresSafeArea()

            subtitleOverlay

            topBar
                .opacity(state.showsControls ? 1 : 0)

            centerControls
                .opacity(state.showsControls ? 1 : 0)

            bottomBar
                .opacity(state.showsControls ? 1 : 0)
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
                    .padding(.bottom, 100)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: state.currentSubtitleText)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                state.dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.85))

            Text(state.title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.black.opacity(0.4), in: Rectangle())
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var centerControls: some View {
        VStack(spacing: 16) {
            Spacer()

            HStack(spacing: 24) {
                Button {
                    state.seek(by: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title2)
                }
                .buttonStyle(PlayerButtonStyle())

                Button {
                    state.togglePlayback()
                } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 38))
                }
                .buttonStyle(PlayerButtonStyle())

                Button {
                    state.seek(by: 10)
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.title2)
                }
                .buttonStyle(PlayerButtonStyle())
            }

            Spacer()
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            scrubber

            HStack(spacing: 16) {
                HStack(spacing: 12) {
                    Button {
                        state.toggleMute()
                    } label: {
                        Image(systemName: muteIcon)
                            .font(.body)
                    }
                    .buttonStyle(PlayerButtonStyle())

                    VolumeSlider(volume: state.volume) { newValue in
                        state.setVolume(newValue)
                    }
                    .frame(width: 80)
                }

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        state.cyclePlaybackRate()
                    } label: {
                        Text("\(state.playbackRate, specifier: "%.2g")x")
                            .font(.caption)
                            .fontWeight(.medium)
                            .monospacedDigit()
                    }
                    .buttonStyle(PlayerButtonStyle())

                    Button {
                        state.toggleSubtitle()
                    } label: {
                        Image(systemName: state.activeSubtitleTrack >= 0 ? "captions.bubble.fill" : "captions.bubble")
                            .font(.body)
                    }
                    .buttonStyle(PlayerButtonStyle())
                    .disabled(state.subtitleURL == nil && state.activeSubtitleTrack < 0)

                    Button {
                        toggleFullScreen()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.body)
                    }
                    .buttonStyle(PlayerButtonStyle())
                }

                Text(timeDisplay)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.leading, 8)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            .padding(.top, 4)
        }
        .background(.black.opacity(0.4), in: Rectangle())
        .frame(maxWidth: .infinity, alignment: .bottom)
    }

    private var scrubber: some View {
        Slider(value: Binding(
            get: { state.currentTime },
            set: { state.seek(to: $0) }
        ), in: 0...max(state.duration, 0.01)) {
            Text("Seek")
        } minimumValueLabel: {
            Text(formatTime(state.currentTime))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
        } maximumValueLabel: {
            Text(formatTime(state.duration))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
        }
        .tint(.white)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 2)
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

    private var timeDisplay: String {
        "\(formatTime(state.currentTime)) / \(formatTime(state.duration))"
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
            if !Task.isCancelled {
                await MainActor.run {
                    state.showsControls = false
                }
            }
        }
    }

    private func toggleFullScreen() {
        guard let window = NSApplication.shared.keyWindow else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            window.toggleFullScreen(nil)
        }
    }
}

struct PlayerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.6 : 0.85))
            .padding(10)
            .background(.ultraThinMaterial, in: Circle())
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
