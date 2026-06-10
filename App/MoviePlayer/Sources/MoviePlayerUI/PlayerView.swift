import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


public struct PlayerView<
    SourcesSidebar: View,
    SubtitlesSidebar: View,
    StreamStatsAccessory: View
>: View {
    private let surfaceCornerRadius: CGFloat = 14
    private let hudChromeControlSize: CGFloat = 36
    private let hudChromeIconFont: CGFloat = 15
    private let transportIconFont: CGFloat = 17
    private let transportIconFrame: CGFloat = 36
    private let transportCapsuleSpacing: CGFloat = 18
    private let transportCapsulePaddingH: CGFloat = 16
    private let transportCapsulePaddingV: CGFloat = 10
    private let playerTopHUDHorizontalInset: CGFloat = 24
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
    @State private var isWindowFullScreen = false

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

    /// Letterbox fill only while the in-window player surface is visible. Cleared during PiP so
    /// AVKit’s “playing in Picture in Picture” placeholder is not covered by SwiftUI black.
    private var showsLetterboxBackdrop: Bool {
        !state.isPictureInPictureActive && !state.isPlaybackChromeHidden
    }

    public var body: some View {
        ZStack {
            if showsLetterboxBackdrop {
                Color.black.ignoresSafeArea()
            }

            // Native AVPlayer rendering layer — always mounted while playback is active.
            AVPlayerLayerView(player: state.player, state: state)
                .ignoresSafeArea()

            if !state.isPlaybackChromeHidden {
            // Elegant native vignetting overlay when controls are showing to elevate legibility
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.78), location: 0),
                        .init(color: .black.opacity(0.42), location: 0.42),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 280)
                .frame(maxHeight: .infinity, alignment: .top)

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.48), location: 0.45),
                        .init(color: .black.opacity(0.82), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 320)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .opacity(state.showsControls ? 1 : 0)
            .animation(state.showsControls ? Self.hudShowAnimation : Self.hudHideAnimation, value: state.showsControls)
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if showsBufferingIndicator {
                playerBufferingIndicator
                    .transition(.opacity)
                    .zIndex(5)
            }

            // Beautiful, floating glassmorphic IINA top bar
            topHUD
                .opacity(state.showsControls ? 1 : 0)
                .allowsHitTesting(state.showsControls)
                .animation(state.showsControls ? Self.hudShowAnimation : Self.hudHideAnimation, value: state.showsControls)

            centerPlaybackOverlay
                .zIndex(3)

            // Stunning, floating glassmorphic IINA control pod
            bottomHUD
                .opacity(state.showsControls ? 1 : 0)
                .allowsHitTesting(state.showsControls)
                .animation(state.showsControls ? Self.hudShowAnimation : Self.hudHideAnimation, value: state.showsControls)

            if let errorMsg = state.errorMessage {
                playbackErrorOverlay(message: errorMsg)
                    .transition(.opacity)
                    .zIndex(8)
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if !state.isPlaybackChromeHidden {
                subtitleOverlay
                    .zIndex(20)
            }
        }
        .overlay {
            if !state.isPlaybackChromeHidden {
            PlayerKeyboardCaptureView(
                state: state,
                onActivity: resetControlFade,
                onSkipBack: { skipBackTrigger += 1 },
                onSkipForward: { skipForwardTrigger += 1 },
                onCommandHeld: { isCommandHeld = $0 },
                onShiftHeld: { isShiftHeld = $0 }
            )
            }
        }
        .overlay {
            if !state.isPlaybackChromeHidden {
            MouseTrackingView(onMove: resetControlFade)
            }
        }
        .overlay {
            PlaybackCursorView(
                showsControls: state.showsControls,
                isActive: state.isPresented && !state.isPlaybackChromeHidden
            )
        }
        .ignoresSafeArea()
        .task {
            isWindowFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) == true
            resetControlFade()
            NotificationCenter.default.post(name: .playerReclaimKeyboardFocus, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isWindowFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isWindowFullScreen = true
            state.pipHostView?.ensureNormalPresentation()
            resetControlFade()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isWindowFullScreen = false
            state.pipHostView?.ensureNormalPresentation()
            resetControlFade()
        }
        .modifier(PlayerSurfaceClip(isEnabled: !isWindowFullScreen, cornerRadius: surfaceCornerRadius))
        .overlay(alignment: .top) {
            if !state.isPlaybackChromeHidden {
                VStack(spacing: 8) {
                    PlayerHUDStatusPillOverlay(pill: state.hudStatusPill)
                    if let warning = state.playbackQualityWarning {
                        Text(warning)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.85), in: Capsule(style: .continuous))
                            .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    @ViewBuilder
    private func hudChromeIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: hudChromeIconFont, weight: .semibold))
            .playerGlassSymbol()
            .frame(width: hudChromeControlSize, height: hudChromeControlSize)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func hudCapsuleSegmentIcon(_ systemName: String, isActive: Bool = false) -> some View {
        Image(systemName: systemName)
            .font(.system(size: hudChromeIconFont, weight: .semibold))
            .playerGlassSymbol()
            .foregroundStyle(isActive ? .black : .primary)
            .frame(width: 46, height: hudChromeControlSize)
            .background(isActive ? Color.white : Color.clear, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
    }

    @ViewBuilder
    private func transportCapsuleIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: transportIconFont, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.primary)
            .frame(width: transportIconFrame, height: transportIconFrame)
            .contentShape(Rectangle())
    }

    private var showsBufferingIndicator: Bool {
        state.isSwitchingSource || state.isBuffering
    }

    private var playerBufferingIndicator: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .shadow(color: .black.opacity(0.9), radius: 10, y: 2)
                .shadow(color: .black.opacity(0.55), radius: 2, y: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityLabel("Buffering")
    }

    private var centerPlaybackOverlay: some View {
        ZStack {
            if !showsBufferingIndicator {
                centerControls
            }
        }
        .animation(.easeInOut(duration: 0.22), value: showsBufferingIndicator)
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
            isVisible: state.showsCustomSubtitleOverlay,
            showsControls: state.showsControls,
            loadProgress: state.subtitleLoadProgress
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
                        hudChromeIcon("xmark")
                            .playerGlassChrome(.circle, strength: .thick)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)

                    // Utilities Capsule — PiP + fit (fullscreen lives above the scrubber)
                    HStack(spacing: 4) {
                        Button {
                            state.togglePictureInPicture()
                        } label: {
                            hudCapsuleSegmentIcon(
                                state.isPictureInPictureActive ? "pip.exit" : "pip.enter",
                                isActive: state.isPictureInPictureActive
                            )
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.05, dampingFraction: 0.95), value: state.isPictureInPictureActive)

                        Button {
                            resetControlFade()
                            state.cycleVideoGravity()
                        } label: {
                            hudCapsuleSegmentIcon("aspectratio")
                        }
                        .buttonStyle(.plain)
                        .help(state.videoGravityHUDTitle)
                    }
                    .padding(.horizontal, 0)
                    .padding(.vertical, 0)
                    .playerGlassChrome(.capsule, strength: .thick)
                }

                Spacer()

                // Top-Right Group: Stream stats (torrent) + Volume + Episodes
                HStack(spacing: 12) {
                    if state.movieId == 0 {
                        Button {
                            nerdStatsPresented.toggle()
                        } label: {
                            hudChromeIcon("externaldrive.connected.to.line.below")
                                .playerGlassChrome(.circle, strength: .thick, isActive: nerdStatsPresented)
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

                    HStack(spacing: 6) {
                        VolumeBoostSlider(value: Binding(
                            get: { Double(state.volume) },
                            set: { state.setVolume(Float($0)) }
                        ))
                        .frame(width: 130)
                        .padding(.leading, 14)

                        Button {
                            state.toggleMute()
                        } label: {
                            PlayerVolumeIcon(
                                isMuted: state.isMuted,
                                volume: state.volume,
                                iconFont: hudChromeIconFont,
                                frameSize: hudChromeControlSize
                            )
                            .foregroundStyle(.primary)
                            .frame(width: 54, height: hudChromeControlSize)
                            .contentShape(Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: state.isMuted)
                        .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.88), value: state.volume)

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
                                hudCapsuleSegmentIcon("list.bullet", isActive: state.isEpisodesSidebarOpen)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .buttonStyle(.plain)
                            .help("Episodes")
                        }
                    }
                    .padding(.horizontal, 0)
                    .padding(.vertical, 0)
                    .playerGlassChrome(.capsule, strength: .thick)
                }
            }
            .padding(.top, 24)
            .padding(.horizontal, playerTopHUDHorizontalInset)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func playbackErrorOverlay(message: String) -> some View {
        ZStack {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 44))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color(red: 0.98, green: 0.36, blue: 0.18))

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
                    .font(.system(size: 24, weight: .bold))
                    .playerGlassSymbol()
                    .frame(width: 68, height: 68)
                    .playerGlassChrome(.circle, strength: .thick)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
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
        .allowsHitTesting(state.showsControls)
        .animation(.spring(response: 0.08, dampingFraction: 0.92), value: state.showsControls)
    }

    private static var hudShowAnimation: Animation {
        .easeIn(duration: 0.18)
    }

    private static var hudHideAnimation: Animation {
        .easeOut(duration: 0.06)
    }

    private var bottomHUD: some View {
        HStack(alignment: .bottom, spacing: 0) {
            // Episodes Sidebar (slides in from left)
            if state.isEpisodesSidebarOpen && !state.episodes.isEmpty {
                episodesSidebar
                    .transition(.move(edge: .leading))
            }
            
            VStack {
                Spacer()

                // Title row + scrubber — shared left edge so elapsed time lines up with title
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .bottom, spacing: 16) {
                        VStack(alignment: .leading, spacing: state.episodeTitle?.isEmpty == false ? 10 : 0) {
                            if let epTitle = state.episodeTitle, !epTitle.isEmpty {
                                Text(epTitle)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .lineLimit(2)
                            }

                            Text(state.seriesName)
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

                        Spacer(minLength: 0)

                        HStack(spacing: 8) {
                            bottomPlaybackOptionsCapsule
                            bottomFullscreenButton
                        }
                    }

                    HStack(alignment: .center, spacing: 10) {
                        Text(formatTime(state.currentTime))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: 36, alignment: .leading)

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
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 36)
            .onHover { hovering in
                isHoveringHUD = hovering
            }
            }
            .frame(maxWidth: .infinity)

            if state.isSourcesSidebarOpen && !state.playbackSources.isEmpty {
                sourcesSidebar()
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .trailing))
            }

            if state.isSubtitlesSidebarOpen {
                subtitlesSidebar()
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: state.isSourcesSidebarOpen)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: state.isSubtitlesSidebarOpen)
    }

    @ViewBuilder
    private var bottomPlaybackOptionsCapsule: some View {
        let showsSources = !state.playbackSources.isEmpty
        if showsSources || state.canOpenSubtitlesSidebar {
            HStack(spacing: 4) {
                if showsSources {
                    Button {
                        resetControlFade()
                        state.isSourcesSidebarOpen.toggle()
                        if state.isSourcesSidebarOpen {
                            state.isEpisodesSidebarOpen = false
                            state.isSubtitlesSidebarOpen = false
                        }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            hudCapsuleSegmentIcon("sharedwithyou", isActive: state.isSourcesSidebarOpen)
                                .symbolEffect(.pulse, isActive: state.isSwitchingSource)
                            if state.isSwitchingSource {
                                ProgressView()
                                    .controlSize(.mini)
                                    .offset(x: 8, y: -8)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Other versions")
                    .disabled(state.isSwitchingSource || state.onSelectPlaybackSource == nil)
                }

                Button {
                    resetControlFade()
                    state.isSubtitlesSidebarOpen.toggle()
                    if state.isSubtitlesSidebarOpen {
                        state.isSourcesSidebarOpen = false
                        state.isEpisodesSidebarOpen = false
                    }
                } label: {
                    hudCapsuleSegmentIcon(
                        state.isSubtitlesSidebarOpen || state.areSubtitlesEnabled
                            ? "captions.bubble.fill"
                            : "captions.bubble",
                        isActive: state.isSubtitlesSidebarOpen || state.areSubtitlesEnabled
                    )
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help("Subtitles")
                .disabled(!state.canOpenSubtitlesSidebar)
            }
            .padding(.horizontal, 0)
            .padding(.vertical, 0)
            .playerGlassChrome(.capsule, strength: .thick)
        }
    }

    private var bottomFullscreenButton: some View {
        Button {
            resetControlFade()
            state.toggleFullScreen()
        } label: {
            hudChromeIcon("arrow.up.left.and.arrow.down.right")
                .playerGlassChrome(.circle, strength: .thick)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Full screen")
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
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity)
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

    private func hdrDiagnosticsSection(from diagnostics: StreamQualityDiagnostics?) -> DiagnosticsPanelSnapshot.Section? {
        guard let diagnostics else { return nil }
        var rows: [DiagnosticsPanelSnapshot.Row] = [
            .init(label: "Probe source", value: diagnostics.source),
        ]
        if let hdr = diagnostics.hdrType?.rawValue {
            rows.append(.init(label: "Detected HDR", value: hdr))
        }
        if let videoRange = diagnostics.videoRange, !videoRange.isEmpty {
            rows.append(.init(label: "VIDEO-RANGE", value: videoRange))
        }
        if let codecs = diagnostics.codecs, !codecs.isEmpty {
            rows.append(.init(label: "CODECS", value: codecs))
        }
        if let resolution = diagnostics.resolution, !resolution.isEmpty {
            rows.append(.init(label: "Top variant", value: resolution))
        }
        if let peakBitrate = diagnostics.peakBitrate, !peakBitrate.isEmpty {
            rows.append(.init(label: "Peak bitrate", value: peakBitrate))
        }
        if let primaries = diagnostics.colorPrimaries, !primaries.isEmpty {
            rows.append(.init(label: "Color primaries", value: primaries))
        }
        if let transfer = diagnostics.colorTransfer, !transfer.isEmpty {
            rows.append(.init(label: "Transfer", value: transfer))
        }
        if let atmos = diagnostics.atmosRendition, !atmos.isEmpty {
            rows.append(.init(label: "Atmos audio", value: atmos))
        } else if diagnostics.audioFormat == .dolbyAtmos {
            rows.append(.init(label: "Atmos audio", value: "Dolby Atmos"))
        }
        guard rows.count > 1 else { return nil }
        return DiagnosticsPanelSnapshot.Section(title: "HDR / Dolby", rows: rows)
    }

    private func showNerdStats() async {
        guard let item = state.player.currentItem,
              let asset = item.asset as? AVURLAsset else { return }

        await state.refreshStreamQualityBadges(manifestURL: asset.url)

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
        var sections: [DiagnosticsPanelSnapshot.Section] = [
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
                    .init(label: "HUD HDR", value: state.hdrType?.rawValue ?? "none"),
                    .init(label: "HUD Atmos", value: state.audioFormat?.rawValue ?? "none"),
                ]
            ),
        ]
        if let hdr = hdrDiagnosticsSection(from: state.streamQualityDiagnostics) {
            sections.append(hdr)
        }
        sections.append(
            DiagnosticsPanelSnapshot.Section(
                title: "Source",
                rows: [
                    .init(label: "URL", value: streamURL.absoluteString),
                ]
            )
        )
        nerdStatsSnapshot = DiagnosticsPanelSnapshot(
            title: "Nerd Stats",
            subtitle: "Updated \(capturedAt.formatted(date: .omitted, time: .standard))",
            capturedAt: capturedAt,
            sections: sections,
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
        let bytes: [UInt8] = [
            UInt8((n >> 24) & 255),
            UInt8((n >> 16) & 255),
            UInt8((n >> 8) & 255),
            UInt8(n & 255),
        ]
        return String(bytes.compactMap { UnicodeScalar($0) }.map(Character.init))
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

private struct PlayerSurfaceClip: ViewModifier {
    let isEnabled: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if isEnabled {
            content.clipShape(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content
        }
    }
}
