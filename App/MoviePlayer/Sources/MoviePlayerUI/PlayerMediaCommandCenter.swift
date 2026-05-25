import AppKit
import Foundation
import MediaPlayer

/// Payload built on `PlayerState`'s main actor; applied on the main dispatch queue for MediaPlayer.
struct NowPlayingPublishPayload: Sendable {
    let title: String
    let albumTitle: String?
    let duration: Double
    let position: Double
    let rate: Double
    let posterURL: URL?
}

/// macOS Control Center / keyboard media keys (play, pause, skip, scrub).
/// MediaPlayer APIs must run on the main dispatch queue — not only `@MainActor`.
final class PlayerMediaCommandCenter: @unchecked Sendable {
    private weak var state: PlayerState?
    private var isActive = false
    private var commandBridge: PlayerRemoteCommandBridge?
    private var cachedArtwork: MPMediaItemArtwork?
    private var artworkPosterURL: URL?
    private var artworkFetchTask: Task<Void, Never>?
    private var pendingPublishWorkItem: DispatchWorkItem?

    init(state: PlayerState) {
        self.state = state
    }

    func activate() {
        performOnMain { [weak self] in
            guard let self, !self.isActive else { return }
            self.isActive = true

            let bridge = PlayerRemoteCommandBridge(center: self)
            self.commandBridge = bridge

            let center = MPRemoteCommandCenter.shared()
            center.playCommand.isEnabled = true
            center.pauseCommand.isEnabled = true
            center.togglePlayPauseCommand.isEnabled = true
            center.skipForwardCommand.isEnabled = true
            center.skipBackwardCommand.isEnabled = true
            center.changePlaybackPositionCommand.isEnabled = true
            center.skipForwardCommand.preferredIntervals = [15]
            center.skipBackwardCommand.preferredIntervals = [15]

            center.playCommand.addTarget(bridge, action: #selector(PlayerRemoteCommandBridge.play(_:)))
            center.pauseCommand.addTarget(bridge, action: #selector(PlayerRemoteCommandBridge.pause(_:)))
            center.togglePlayPauseCommand.addTarget(
                bridge,
                action: #selector(PlayerRemoteCommandBridge.togglePlayPause(_:))
            )
            center.skipForwardCommand.addTarget(bridge, action: #selector(PlayerRemoteCommandBridge.skipForward(_:)))
            center.skipBackwardCommand.addTarget(bridge, action: #selector(PlayerRemoteCommandBridge.skipBackward(_:)))
            center.changePlaybackPositionCommand.addTarget(
                bridge,
                action: #selector(PlayerRemoteCommandBridge.changePlaybackPosition(_:))
            )
        }
    }

    func deactivate() {
        performOnMain { [weak self] in
            guard let self else { return }
            self.pendingPublishWorkItem?.cancel()
            self.pendingPublishWorkItem = nil
            guard self.isActive else { return }
            self.isActive = false

            self.artworkFetchTask?.cancel()
            self.artworkFetchTask = nil
            self.cachedArtwork = nil
            self.artworkPosterURL = nil

            if let bridge = self.commandBridge {
                let center = MPRemoteCommandCenter.shared()
                center.playCommand.removeTarget(bridge)
                center.pauseCommand.removeTarget(bridge)
                center.togglePlayPauseCommand.removeTarget(bridge)
                center.skipForwardCommand.removeTarget(bridge)
                center.skipBackwardCommand.removeTarget(bridge)
                center.changePlaybackPositionCommand.removeTarget(bridge)
            }
            self.commandBridge = nil

            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            if #available(macOS 13.0, *) {
                MPNowPlayingInfoCenter.default().playbackState = .stopped
            }
        }
    }

    func publish(_ payload: NowPlayingPublishPayload) {
        schedulePublish(payload, immediate: false)
    }

    fileprivate func handlePlay() {
        runOnPlayerState { state, center in
            state.play()
            if let payload = state.makeNowPlayingPayload() {
                center.schedulePublish(payload, immediate: true)
            }
        }
    }

    fileprivate func handlePause() {
        runOnPlayerState { state, center in
            state.pause()
            if let payload = state.makeNowPlayingPayload() {
                center.schedulePublish(payload, immediate: true)
            }
        }
    }

    fileprivate func handleTogglePlayPause() {
        runOnPlayerState { state, center in
            state.togglePlayback()
            if let payload = state.makeNowPlayingPayload() {
                center.schedulePublish(payload, immediate: true)
            }
        }
    }

    fileprivate func handleSkipForward() {
        runOnPlayerState { state, center in
            state.seek(by: 15)
            if let payload = state.makeNowPlayingPayload() {
                center.schedulePublish(payload, immediate: true)
            }
        }
    }

    fileprivate func handleSkipBackward() {
        runOnPlayerState { state, center in
            state.seek(by: -15)
            if let payload = state.makeNowPlayingPayload() {
                center.schedulePublish(payload, immediate: true)
            }
        }
    }

    fileprivate func handleChangePlaybackPosition(_ time: TimeInterval) {
        runOnPlayerState { state, center in
            state.seek(to: time)
            if let payload = state.makeNowPlayingPayload() {
                center.schedulePublish(payload, immediate: true)
            }
        }
    }

    private func runOnPlayerState(
        _ work: @escaping @MainActor (PlayerState, PlayerMediaCommandCenter) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.isActive, let state = self.state else { return }
            work(state, self)
        }
    }

    private func schedulePublish(_ payload: NowPlayingPublishPayload, immediate: Bool) {
        performOnMain { [weak self] in
            guard let self, self.isActive else { return }
            self.pendingPublishWorkItem?.cancel()

            let work = DispatchWorkItem { [weak self] in
                self?.applyNowPlayingOnMainThread(payload)
            }
            self.pendingPublishWorkItem = work

            if immediate {
                work.perform()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
            }
        }
    }

    private func applyNowPlayingOnMainThread(_ payload: NowPlayingPublishPayload) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isActive else { return }

        if let posterURL = payload.posterURL {
            scheduleArtworkFetch(from: posterURL)
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: payload.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: payload.position,
            MPNowPlayingInfoPropertyPlaybackRate: payload.rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if payload.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = payload.duration
        }
        if let albumTitle = payload.albumTitle {
            info[MPMediaItemPropertyAlbumTitle] = albumTitle
        }
        if let posterURL = payload.posterURL, artworkPosterURL == posterURL, let cachedArtwork {
            info[MPMediaItemPropertyArtwork] = cachedArtwork
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info

        // Defer playbackState — updating both in one stack frame triggers MP queue asserts on macOS.
        let rate = payload.rate
        DispatchQueue.main.async {
            if #available(macOS 13.0, *) {
                center.playbackState = rate > 0 ? .playing : .paused
            }
        }
    }

    private func scheduleArtworkFetch(from url: URL) {
        guard artworkPosterURL != url || cachedArtwork == nil else { return }
        artworkPosterURL = url
        cachedArtwork = nil
        artworkFetchTask?.cancel()
        artworkFetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
                guard let image = NSImage(data: data), image.size.width > 1, image.size.height > 1 else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                guard !Task.isCancelled else { return }

                self.performOnMain { [weak self] in
                    guard let self, self.artworkPosterURL == url else { return }
                    self.cachedArtwork = artwork
                    Task { @MainActor [weak self] in
                        guard let self, let state = self.state, let payload = state.makeNowPlayingPayload() else { return }
                        self.schedulePublish(payload, immediate: false)
                    }
                }
            } catch {
                // Keep app icon fallback if poster fetch fails.
            }
        }
    }

    private func performOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

/// NSObject bridge so `MPRemoteCommandCenter` targets are removed precisely on deactivate.
private final class PlayerRemoteCommandBridge: NSObject {
    private weak var center: PlayerMediaCommandCenter?

    init(center: PlayerMediaCommandCenter) {
        self.center = center
    }

    @objc func play(_: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        DispatchQueue.main.async { [weak center] in
            center?.handlePlay()
        }
        return .success
    }

    @objc func pause(_: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        DispatchQueue.main.async { [weak center] in
            center?.handlePause()
        }
        return .success
    }

    @objc func togglePlayPause(_: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        DispatchQueue.main.async { [weak center] in
            center?.handleTogglePlayPause()
        }
        return .success
    }

    @objc func skipForward(_: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        DispatchQueue.main.async { [weak center] in
            center?.handleSkipForward()
        }
        return .success
    }

    @objc func skipBackward(_: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        DispatchQueue.main.async { [weak center] in
            center?.handleSkipBackward()
        }
        return .success
    }

    @objc func changePlaybackPosition(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let event = event as? MPChangePlaybackPositionCommandEvent else {
            return .commandFailed
        }
        let time = event.positionTime
        DispatchQueue.main.async { [weak center] in
            center?.handleChangePlaybackPosition(time)
        }
        return .success
    }
}
