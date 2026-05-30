import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


public struct AVPlayerLayerView: NSViewRepresentable {
    private let player: AVPlayer
    private let state: PlayerState

    public init(player: AVPlayer, state: PlayerState) {
        self.player = player
        self.state = state
    }

    public func makeNSView(context: Context) -> PlayerSurfaceHost {
        let host = PlayerSurfaceHost()
        host.configure(player: player, state: state)
        DispatchQueue.main.async {
            state.setupPiP(with: host.playerContainer.playerLayer)
        }
        return host
    }

    public func updateNSView(_ host: PlayerSurfaceHost, context: Context) {
        host.configure(player: player, state: state)
        if state.isPresented {
            state.setupPiP(with: host.playerContainer.playerLayer)
        }
        host.needsLayout = true
    }

    public static func dismantleNSView(_ host: PlayerSurfaceHost, coordinator: ()) {
        host.teardown()
    }
}

/// Layout anchor inside SwiftUI; `PlayerContainerView` stays here during normal playback.
public final class PlayerSurfaceHost: NSView {
    let playerContainer = PlayerContainerView()
    private var lastLayoutLogSignature = ""

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(player: AVPlayer, state: PlayerState) {
        playerContainer.bind(to: state, anchor: self)
        playerContainer.playerLayer.player = player
        playerContainer.playerLayer.videoGravity = state.videoGravity
        attachPlayerContainer()
    }

    func teardown() {
        playerContainer.restoreAfterPictureInPicture()
        playerContainer.bind(to: nil, anchor: nil)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachPlayerContainer()
    }

    public override func layout() {
        super.layout()
        attachPlayerContainer()
        // #region agent log
        let onHost = playerContainer.superview === self
        let signature = "\(Int(bounds.width))x\(Int(bounds.height))|\(Int(playerContainer.frame.width))x\(Int(playerContainer.frame.height))|\(onHost)"
        if signature != lastLayoutLogSignature, bounds.width > 1, bounds.height > 1 {
            lastLayoutLogSignature = signature
            DebugAgentLog.write(
                hypothesisId: "H1,H5",
                location: "CorePlayer.swift:PlayerSurfaceHost.layout",
                message: "surface host layout",
                data: [
                    "hostBounds": NSStringFromRect( bounds),
                    "containerFrame": NSStringFromRect( playerContainer.frame),
                    "containerOnHost": String(onHost),
                ]
            )
        }
        // #endregion
    }

    private func attachPlayerContainer() {
        if playerContainer.superview !== self {
            playerContainer.removeFromSuperview()
            addSubview(playerContainer)
        }
        playerContainer.frame = bounds
        playerContainer.autoresizingMask = [.width, .height]
    }
}

public final class PlayerContainerView: NSView {
    private weak var playerState: PlayerState?
    private weak var presentationAnchor: PlayerSurfaceHost?
    private var isReparentedForPictureInPicture = false

    public var playerLayer: AVPlayerLayer {
        guard let playerLayer = layer as? AVPlayerLayer else {
            fatalError("PlayerContainerView requires AVPlayerLayer backing layer")
        }
        return playerLayer
    }

    func bind(to state: PlayerState?, anchor: PlayerSurfaceHost?) {
        playerState?.pipHostView = nil
        playerState = state
        presentationAnchor = anchor
        state?.pipHostView = self
    }

    /// Briefly moves the layer host above `NSHostingController.view` so PiP can attach (not under SwiftUI).
    func prepareForPictureInPicture() {
        guard let anchor = presentationAnchor,
              let contentView = anchor.window?.contentView,
              !isReparentedForPictureInPicture
        else { return }

        let hostingRoot = Self.largestHostingSubview(of: contentView) ?? contentView
        let targetFrame = anchor.convert(anchor.bounds, to: contentView)
        removeFromSuperview()
        contentView.addSubview(self, positioned: .above, relativeTo: hostingRoot)
        frame = targetFrame
        isReparentedForPictureInPicture = true
        layoutSubtreeIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        // #region agent log
        DebugAgentLog.write(
            hypothesisId: "H2",
            location: "CorePlayer.swift:prepareForPictureInPicture",
            message: "reparented for PiP",
            data: [
                "targetFrame": NSStringFromRect( targetFrame),
                "anchorBounds": NSStringFromRect( anchor.bounds),
            ]
        )
        // #endregion
    }

    func restoreAfterPictureInPicture() {
        guard isReparentedForPictureInPicture, let anchor = presentationAnchor else { return }
        removeFromSuperview()
        anchor.addSubview(self)
        frame = anchor.bounds
        autoresizingMask = [.width, .height]
        isReparentedForPictureInPicture = false
        // #region agent log
        DebugAgentLog.write(
            hypothesisId: "H2",
            location: "CorePlayer.swift:restoreAfterPictureInPicture",
            message: "restored after PiP",
            data: [
                "anchorBounds": NSStringFromRect( anchor.bounds),
                "containerFrame": NSStringFromRect( frame),
            ]
        )
        // #endregion
    }

    private static func largestHostingSubview(of contentView: NSView) -> NSView? {
        contentView.subviews
            .filter { isHostingRelatedView($0) }
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }

    private static func isHostingRelatedView(_ view: NSView) -> Bool {
        let typeName = String(describing: type(of: view))
        if typeName.localizedCaseInsensitiveContains("hosting") {
            return true
        }
        return view.className.localizedCaseInsensitiveContains("hosting")
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
        // #region agent log
        if isReparentedForPictureInPicture || bounds.width < 200 || bounds.height < 200 {
            let superName = superview.map { String(describing: type(of: $0)) } ?? "nil"
            DebugAgentLog.write(
                hypothesisId: "H2,H5",
                location: "CorePlayer.swift:PlayerContainerView.layout",
                message: "container layout anomaly",
                data: [
                    "reparented": String(isReparentedForPictureInPicture),
                    "bounds": NSStringFromRect( bounds),
                    "layerFrame": NSStringFromRect( playerLayer.frame),
                    "superview": superName,
                ]
            )
        }
        // #endregion
    }
}
